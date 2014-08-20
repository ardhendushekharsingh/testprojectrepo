#!/usr/local/bin/perl-journals

=head1 NAME

load - Load journals log files into the stats database

=head1 VERSION

$Id$

=head1 SYNOPSIS

  load [--devgroup=DEVGROUP] [--test] [--progress] [--no-userids] \
    --date=DATE [--worker=NUMBER] [--queue-dir=DIRECTORY] [FILE ...]

=head1 DESCRIPTION

Reads the specified logfile(s) (or stdin, if none are specified), and
dimensionalizes the data into the stats database.

=head1 OPTIONS

=over

=item --devgroup=DEVGROUP

Performs ICS queries against the server configured in the specified devgroup.
The default is based on the script's location.

=item --db-server=DB-SERVER

Performs journals database queries against the specified instance of the
database. The default is based on host the script is run from.

=item --test

Don't update the database.
B<WARNING:> This is really only useful during development,
and is likely to exhaust available memory.

=item --progress

Display progress by printing one dot per thousand log entries processed.

=item --no-userids

Don't update the C<dim_userid> and C<dim_ticket_user> tables. This is most
useful to reduce the time spent during bulk loading, when the script may be
run several times between queries.

=item --date=DATE

Specifies the date in which accesses in the log file were made.

=item --worker=NUMBER

Specifies which worker instance to run as. This allows parallel processing
of the log files.

=item --queue-dir=DIRECTORY

Specifies an alternate directory to move the resulting SQL*Loader file to, in
place of the default F</ejs/stats/queue>. The file will also be hardlinked into
F</ejs/stats/queue2>, regardless of this option's setting.

=back

=head1 AUTHOR

Copyright (C) IOP Publishing Ltd 2007-2011

	Peter Haworth <pmh@edison.ioppublishing.com>

=cut

use IOPP::Dev;
use IOPP::DevGroup qw($devgroup);

use Cache::Numbered;
use Carp;
use Date::Calc qw(Delta_Days);
use DBIx::RetryOverDisconnects;
use Fcntl qw(:DEFAULT);
use Getopt::Long;
use IOPP::Country;
use IP::Country;
use Journals::Common qw($dir_stats);
use Journals::ICS::REST;
use Journals::Model;
use Journals::Model::Journal::IOP;
use Journals::Model::Volume;
use Journals::Model::Issue;
use Journals::Model::Article::IOP;
use MIME::Base64 qw(decode_base64);
use Data::Dumper;
use strict;
use warnings;

# Don't load journal-specific model classes
Journals::Model->classes_are_autoloaded(0);

use Carp();
$SIG{__DIE__}=sub{ die Carp::longmess(@_); };

# Process command line options
GetOptions(\my %opts,
  'devgroup=s',
  'progress!',
  'test!',
  'no-userids!',
  'date=s',
  'worker=i',
  'queue-dir=s',
) or die "Usage: $0 [--devgroup=DEVGROUP] [--progress] [--test] [--no-userids] [--date=DATE] [--worker=NUMBER] [--queue-dir=DIRECTORY] [FILE ...]\n";
if(my $dg=$opts{devgroup}){
  $devgroup=$devgroup->get_group($dg)
    or die "No such devgroup: $dg\n";
}
$opts{worker}||=0;

my $progress_fname="$dir_stats/load_progress.$opts{worker}";
sysopen my $progress_fh,$progress_fname,O_CREAT|O_EXCL|O_WRONLY
  or $!{EEXIST} and die "Previous load still in progress\n"
  or die "Can't open $progress_fname: $!";
$progress_fh->autoflush(1);
print $progress_fh "Started\n"
  or die "Can't write $progress_fname: $!";

# Caches for various things we'll need frequently
# XXX Try not to hold these in memory if possible
my(%identity_by_id,%identity_by_key);

# Establish communications with the various servers
my $model_live=Journals::Model->new;
my $model_test=Journals::Model->new;
$model_test->is_test(1);
my $jdbh=$model_live->db_connect(db_server => $opts{'db-server'})
  or die "Can't connect to journals database: $!";
my $rest=Journals::ICS::REST->instance;
my $dbh=Journals::Model::Database->db_connect_other(mssql =>
  connect_class => 'DBIx::RetryOverDisconnects',
  attrs => {
    ReconnectRetries => 5,   # How many reconnect attempts per disconnect
    ReconnectInterval => 60, # How long to wait between reconnect attempts
    ReconnectTimeout => 30,  # How long to wait for each reconnection attempt
  },
)
  or die "Can't connect to stats database: $!";
# XXX We should really have AutoCommit=0 for performance, but that makes
#     concurrency really hard, as dimension updates won't be seen
if($opts{test}){
  # Make sure we can roll back any changes we make in test mode
  $dbh->{AutoCommit}=0;
}
my $cc_reg=IP::Country->new;

my %collections=(
  # XXX These aren't in the database for some reason
  select => 'IOP Select',
  ff30 => "This Month's Papers",
);
{
  my $sth=$jdbh->prepare(q(
    select cln_id,cln_name
    from jnl_collections
  ));
  $sth->execute;
  while(my($code,$name)=$sth->fetchrow_array){
    $collections{$code}=$name;
  }
}


my %versions=(
  'version=2' => [qw(
    date time ip_address - service url - iop_session_id username
    page_type issn volnum issnum artnum filename http_status - -
    license_id - referrer options user_agent time_start time_trans
    time_access - time_content identity_id_primary userid collection_id -
    version request_id identity_ids ext_auth_service ext_auth_id -
    ics_session_id no_count
  )],
);

my(%line);
my %dimensions=(
  access => {
    # Managed by process_access()
    col_val => 'access_id',
    sub_insert => sub{
      my($dim,$key,$value)=@_;
      my @vals=@{$line{_access_values}};
      my $sth=$dim->{sth_insert}||=$dbh->prepare(q(
        insert into dim_access(access_key,access_id,
	  access_role,free_reason_code,free_reason_name,
	  collection_code,collection_name,age_years,age_days
	)
	values(?,?,
	  ?,?,?,
	  ?,?,?,?
	)
      ));
      $sth->execute($key,$value,@vals);
    },
    cache_opts => {
      # We get about 9000 per day
      high_watermark => 5000,
      low_watermark => 4000,
    },
  },
  content_item => {
    # Managed by process_content()
    cache_opts => {
      # ~170k per day
      high_watermark => 20000,
      low_watermark => 15000,
    },
  },
  country => {
    col_val => 'country_code',
    sub_normalize => sub{
      my($dim,$value)=@_;
      if(my $country=IOPP::Country->from_code($value)){
        $value=$country->code2;
      }
      uc $value;
    },
    sub_insert => sub{
      my($dim,$key,$value)=@_;
      my $name;
      if(my $country=IOPP::Country->from_code($value)){
        $name=$country->name;
	$value=$country->code2;
      }
      $value=uc $value;
      my $sth=$dim->{sth_insert}||=$dbh->prepare(q(
        insert into dim_country(country_key,country_code,country_name)
	values(?,?,?)
      ));
      $sth->execute($key,$value,$name);
    },
    # Cache everything in memory - there are only about 200 countries
    cache_memory => {},
  },
  date => {
    col_val => 'date_value',
    sub_insert => sub{
      my($dim,$key,$value)=@_;
      my $sth=$dim->{sth_insert}||=$dbh->prepare(q(
        insert into dim_date(date_key,date_value,
	  year,quarter,
	  month_num,month_name,
	  day_of_month,day_of_week,
	  week_num
	)
	values(?,convert(date,?),
	  ?,?,
	  ?,DATENAME(month, ?),
	  ?,DATENAME(weekday,?),
	  DATEPART(week,?) 
	)
      ));
      my($yyyy,$mm,$dd)=split '-',$value;
      my $quarter='Q'.int(($mm+2)/3);
     
      $sth->execute($key,$value,
        $yyyy,$quarter,$mm,$value,$dd,$value,$value
      );
    },
    # Cache everything in memory - we only load a couple of days at a time
    cache_memory => {},
  },
  external_authen => {
    # Managed by process_external_auth()
    cache_opts => {
      # There aren't many
      high_watermark => 2000,
      low_watermark => 1500,
    },
  },
  http_status => {
    # Cache everything in memory - there aren't many status codes
    cache_memory => {},
  },
  ics_session => {
    # Handled by process_identities()
    col_val => 'ics_session_id',
    cache_opts => {
      # hundreds of thousands per day
      high_watermark => 100000,
      low_watermark => 90000,
    },
  },
  identity => {
    # Handled by identity_by_id()
    col_val => 'identity_id',
  },
  ip_address => {
    cache_opts => {
      # ~40k per day
      high_watermark => 20000,
      low_watermark => 15000,
    },
  },
  license => {
    # Handled by process_license()
  },
  page_type => {
    col_val => 'page_type_exp',
    cache_opts => {
      # hundreds per day
      high_watermark => 1000,
      low_watermark => 500,
    },
    sub_insert => sub{
      my($dim,$key,$value)=@_;
      my $sth=$dim->{sth_insert}||=$dbh->prepare(q(
        insert into dim_page_type(page_type_key,
	  page_type,page_type_exp
	) values(?,
	  ?,?
	)
      ));
      my $value_short=$value=~/\A([\w\-]+)/ ? $1 : '-';
      $sth->execute($key,
        $value_short,$value
      );
    },
  },
  ref_target => {
    # There shouldn't be too many of these to hold in memory
    cache_memory => {},
  },
  url => {
    sub_normalize => sub{
      my($dim,$value)=@_;
      return $value=~m#\A\w+://[^/]# ? $value : undef;
    },
    sub_insert => sub{
      my($dim,$key,$value)=@_;
      my($host,$path,$query)=$value=~m#\A\w+://([^/]+)(/[^\?]*)?(?:\?(.*))?\z#;
      if($host){
        $path||='/';
      }else{
        $host=$path='UNKNOWN';
      }
      my $sth=$dim->{sth_insert}||=$dbh->prepare(q(
        insert into dim_url(url_key,url,host,path,query)
	values(?,?,?,?,?)
      ));
      $sth->execute($key,$value,$host,$path,$query);
    },
  },
  referrer => {
    sub_normalize => sub{
      my($dim,$value)=@_;
      return $value=~m#\A[\020-\177]+\z# ? $value : undef;
    },
    sub_insert => sub{
      my($dim,$key,$value)=@_;
      my $host=($value=~m#\A\w+://([^/]+)# ? lc $1 : undef);
      my $sth=$dim->{sth_insert}||=$dbh->prepare(q(
        insert into dim_referrer(referrer_key,referrer,host)
	values(?,?,?)
      ));
      $sth->execute($key,$value,$host);
    },
  },
  service => {
    col_val => 'service_code',
    # There are only a handful of services, so they'll fit into memory
    cache_memory => {},
  },
  session_identity => {
    # Handled by process_identities()
    cache_opts => {
      # few thousand per day
      high_watermark => 3000,
      low_watermark => 2000,
    },
  },
  syndicategroup => {
    cache_opts => {
      # Only a few thousands rows total
      high_watermark => 5000,
      low_watermark => 3000,
    },
  },
  ticket_session => {
    col_val => 'ticket_session_id',
    cache_opts => {
      # hundreds of thousands per day
      high_watermark => 10000,
      low_watermark => 8000,
    },
  },
  user_agent => {
    cache_opts => {
      # several thousand per day
      high_watermark => 5000,
      low_watermark => 4000,
    },
  },
  userid => {
    # Keys are held in memory, but they're stored directly in this hash
  },
  search => {
    # Managed by process_search()
    cache_opts => {
      # There aren't many repeats
      high_watermark => 2000,
      low_watermark => 1500,
    },
  },
  alert_profile => {
    cache_opts => {
      high_watermark => 2000,
      low_watermark => 1500,
    },
    sub_normalize => sub{
      my($dim,$value)=@_;
      my $service_g=$line{service_generic};
      return undef
        unless defined $value && defined $service_g;
      "$service_g/$value";
    },
  },
);
my %line_count;


$dbh->set_callback(afterReconnect => sub{
  warn "Reconnected to database at line $line_count{Total}\n";
  while(my($name,$dim)=each %dimensions){
    while(my $key=each %$dim){
      $key=~/\Asth/ or next;
      delete $dim->{$key};
    }
  }
  seq_reset();
  Journals::Model::Database->db_init_other(stats => $dbh);
});


# Set up insert statement and processing
my @fact_cols=(
  [request_key =>	'seq',10000],
  [request_id =>	'col'],
  [year =>		'col'],
  [date_key =>		'dim'],
  [request_timestamp =>		'sub',sub{ "@{$_[0]}{'date','time'}" }],
  [service_key =>	'dim'],
  [ticket_session_key =>'dim',col => 'iop_session_id'],
  [ip_address_key =>	'dim'],
  [country_key_ip =>	'sub',sub{
    my $ip_address=$_[0]{ip_address}
      or return undef;
    my $cc=$cc_reg->inet_atocc($ip_address)
      or return undef;
    return undef if $cc!~/\A[A-Z][A-Z]\z/;
    dim_fetch($cc,dim => 'country');
  }],
  [country_key_inst =>	'col'], # Produced by identity pre-processing
  [userid =>		'sub',sub{
    # Normalize userid
    if(my($userid)=($_[0]{userid} || '')=~/\A0*([1-9]\d*)\z/){
      # Make sure there's a record in the lookup table
      # but don't fill it in for now - leave that for the post-load fixup
      my $dim=$dimensions{userid}||={};

      # Cache it directly in the dimension -  there aren't enough to blow memory
      # userids are naturally distinct from dimension control keys
      $dim->{$userid}++
        and return $userid;
      my $sth_fetch=$dim->{sth_fetch}||=$dbh->prepare(q(
        select 1
	from dim_userid
	where userid=?
      ));
      my $attempted;
      insert_userid: {
	$sth_fetch->execute($userid);
	if($sth_fetch->fetchrow_arrayref){
	  $sth_fetch->finish;
	}else{
	  my $sth_insert=$dim->{sth_insert}||=$dbh->prepare(q(
	    insert into dim_userid(userid)
	    values(?)
	  ));
	  eval{
	    $sth_insert->execute($userid);
	  } or do{
	    $attempted++ and die;
	    redo insert_userid;
	  };
	}
      }
      return $userid;
    }else{
      return undef;
    }
  }],
  [page_type_key =>	'dim',col => 'page_type_exp'],
  [identity_key_primary =>'col'], # Produced by identity pre-processing
  [identity_key_license =>'col'], # Produced by identity/license pre-processing
  [user_agent_key =>	'dim'],
  [from_alert =>	'sub',sub{ bool($_[0]{alert_profile_id},'notnull'); }],
  [license_key =>	'col'], # Produced by license pre-processing
  [http_status_key =>	'dim'],
  [access_key =>	'col'],
  [content_item_key =>	'col'], # Produced by content_item pre-procesing
  [filename_key =>	'dim'],
  [referrer_key =>	'dim'],
  [ref_target_key =>	'dim'],
  [rss_type_key =>	'dim'],
  [include_identity =>	'col'], # Produced by identity pre-processing
  [include_status =>	'sub',sub{
    my($line)=@_;
    my $status=$line->{http_status} or return undef;
    my $page_type=$line->{page_type};
    return undef if $page_type eq 'alert';
    bool(
      scalar(!$line->{no_count} && $page_type ne 'IGNORE')
      && (
        $status=~/\A2/ # success
	|| $line->{service} eq 'Sold' # Sold Titles fulltext redirect
	  && $page_type=~/\A(?:article|ref|cite|mmedia|postto)\z/
      ),
      'notnull'
    );
  }],
  [ics_session_key =>	'col'], # Produced by identity pre-processing
  [external_authen_key => 'col'], # Produced by process_external_auth()
  [syndicategroup_key => 'col'], # Produced by identity pre-processing
  [url_key =>		'dim'],
  [search_key =>	'col'], # Produced by search processing
  [alert_profile_key =>	'dim',col => 'alert_profile_id'],
  [usage_count => 'sub',sub{
    my($line)=@_;
    my $page_type=$line->{page_type};
    my $chapters=$line->{chapters};
    if($page_type eq 'BOOK_DOWNLOAD_EPUB' || $page_type eq 'BOOK_DOWNLOAD_PDF'){
      return $chapters;
    }else{
      return undef;
    }
  }],
);

# Generate SQL*Loader header
my %partitions;
# XXX Write data to separate compressed file, and load with 'infile "-"' or 'infile /dev/stdin'
my $sql_header= <<'!EOF!';
  options(skip_index_maintenance=true)
  load data
  infile *
  append into table fact_request
-- XXX Partitioning isn't implemented on our server yet
-- partition fact_request_$year
  fields terminated by "," optionally enclosed by '"'
  trailing nullcols
  (
!EOF!
{
  # Fetch column types
  my $sth=$dbh->column_info(undef,undef,'FACT_REQUEST_LOAD',undef);
  print "Column_info", Dumper($sth);
  $sth->execute;
  my %sql_cols;
  while(my $row=$sth->fetchrow_hashref){
    my($name,$type,$prec)=@$row{'COLUMN_NAME','TYPE_NAME','BUFFER_LENGTH'};
    print "------------\n";
    print "Column_name", Dumper($name);
    print "Column_type", Dumper($type);
    print "Column_prec", Dumper($prec);
    if($type=~/CHAR/){
      $type="CHAR($prec)";
    }elsif($type=~/date/){
      $type='date "YYYY-MM-DD HH24:MI:SS"';
    }elsif($type=~/int/){
      $type='int';
    }elsif($type=~/time/){
      $type='time';
    }elsif($type=~/char/){
      $type='char';
    }elsif($type=~/bit/){
      $type='bit';
    }elsif($type=~/FLOAT/){
      $type='FLOAT';
    }else{
      die "Unknown column type: $type";
    }
    $sql_cols{$name}="$name $type";
  print "SQL_cols:---", Dumper($sql_cols{$name});
  }

  print "------------\n";  
  #print "fact_cols:---", Dumper(@fact_cols);
  print "------------\n";  

  my $sep=' ';
  for(@fact_cols){
    my $name=$_->[0];
    print "col_name:---", Dumper($name);
    print "sql_cols:col_name:---", Dumper($sql_cols{uc $name});

    my $sql=$sql_cols{uc $name}
      or die "Can't find definition for column $name";
    $sql_header.="$sep      $sql\n";
    $sep=',';
  }
  $sql_header.=")\nbegindata\n";
}

# XXX Recalculate statistics every week/month/whatever

print $progress_fh "Initialized\n"
  or die "Can't write $progress_fname: $!";


# Read log file, and produce SQL loader file
++$|;
my $is_live=$model_live->is_live;
my $start_time=time;
print $progress_fh "Loading "
  or die "Can't write $progress_fname: $!";
print "Loading " if $opts{progress};
my $o_date;
LINE: while(<>){
  if(not ++$line_count{Total}%1000){
    print $progress_fh '.'
      or die "Can't write $progress_fname: $!";
    print '.'
      if $opts{progress};
  }
  %line=();
  chomp;
  # Figure out which format the line is in, parse it, and make sure it's valid
  if(/\A\d\d\d\d-\d\d-\d\d$;/o && !/\0/){
    # Old positional field format
    utf8::upgrade($_);
    my @cols=map $_ eq '' ? undef : $_,split $;,$_,-1;
    my $version=$cols[32]
      or ++$line_count{invalid_no_version}, next;
    my $col_names=$versions{$version}
      or ++$line_count{invalid_bad_version}, next;
    @cols>$#$col_names
      or ++$line_count{invalid_short_line}, next;
    @line{@$col_names}=@cols;

    # Pull miscellaneous fields from options into the main field
    {
      my %log_options=map split('=',$_,2),grep $_,split /\&/,$line{options} || '';
      $line{alert_profile_id}||=$log_options{profile} || $log_options{alert};
      $line{ref_target}||=$log_options{target};
      $line{rss_type}||=$log_options{rss};
    }
    ++$line_count{old_format};
  }elsif(/\A\w+=[^=]*[&;]/){
    # New name=value pair format

    # Check for badly encoded entries
    if(/%(?![a-zA-Z0-9]{2})/){
      ++$line_count{invalid_encoding};
      next LINE;
    }
    for(split /[&;]/){
      my($key,$val)=split '=',$_,2;
      y/+/ /, s/%(\w\w)/chr hex $1/ge
        for $key,$val;
      utf8::decode($val);
      $line{$key}=$val
        if defined($val) && $val ne '';
    }
    ($line{date} || '')=~/\A\d\d\d\d-\d\d-\d\d\z/
      && ($line{time} || '')=~/\A\d\d:\d\d:\d\d\z/
        or ++$line_count{invalid_bad_time}, next LINE;
    ++$line_count{new_format};
  }else{
    # Something else
    ++$line_count{invalid_bad_format};
    next LINE;
  }
  if(my $type=
    !$line{page_type}
      && 'page_type_missing'
  || $line{page_type}!~/\S/
    && 'page_type_space'
  || $line{page_type}=~/[^\0-\177]/
    && 'page_type_not_ascii'
  || ($line{ip_address} || '0.0.0.0')!~/\A\d+(?:\.\d+){3}\z/
    && 'ip_address'
  || length($line{iop_session_id} || '')!~/\A(?:22|36|0)\z/
    && 'ics_session_id_length'
  || ($line{ics_session_id} || '20070101-8yg8yg38yg38yw8ef')!~/\A\d{8}-\w+\z/
    && 'ics_session_id_format'
  || !$line{service}
    && 'no_service'
  ){
    ++$line_count{"invalid_$type"};
    next LINE;
  }

  # Exclude local accesses
  if($is_live && ($line{ip_address} || '')=~/\A(?:
    193\.(?:61\.87|128\.223|131\.119)\.\d+                              # IOPP
  | 194\.200\.94\.\d+                                                   # IOP
  | 172\.1[6-9]\.\d+\.\d+ | 172\.2\d\.\d+\.\d+ | 172\.3[01]\.\d+\.\d+   # Priv
  | 127\.[\d.]+                                                         # Local
  | 10\.[\d.]+ # XXX Should we really exclude these?                    # Priv
  )\z/x){
    ++$line_count{local};
    next LINE;
  }

  # Calculate generic service type
  if($line{service} eq 'IOPscience'){
    $line{service_is_iopscience}=1;
    $line{service_generic}='IOPscience';
  }elsif($line{service}
  =~/\A(?:EJ|Select|Sold|Stacks|Stacks::Data|Info|Librarians)\z/
  ){
    $line{service_is_ej}=1;
    $line{service_generic}='EJ';
  }else{
    $line{service_generic}='unknown';
  }

  # Wipe date-based caches on date change
  if($o_date && $line{date} ne $o_date){
    for my $dimension(qw(content_item)){
      my $dim=$dimensions{$dimension} or next;
      if(my $cache=$dim->{cache_memory}){
        %$cache=();
      }elsif($dim->{cache_opts}){
        delete $dim->{cache};
      }
    }
  }
  $o_date=$line{date};

  # Pre-process page type
  my $page_type_exp=$line{page_type};
  if($line{service_is_ej}){
    if($page_type_exp eq 'article' and my $filename=$line{filename}){
      # Distinguish between different types of full text
      if(my($ext)=$filename=~/\.(\w+)(?:\.(?:gz|bz|bz2|Z))?\z/i){
        $page_type_exp.="/\L$ext";
      }
    }else{
      # Strip bogus trailing query parameters
      $page_type_exp=~s/[?&;].*//s;
      $page_type_exp='-' unless $page_type_exp=~/\S/;

      # Normalize page_type
      $line{page_type}=$page_type_exp=~/\A([\w\-]+)/ ? $1 : '-';
    }
  }
  $line{page_type_exp}=$page_type_exp;

  # Pre-process identities, to figure out the primary
  process_identities()
    if $line{identity_ids};

  # Pre-process external authentication details
  process_external_auth()
    if $line{ext_auth_service};

  # Pre-process search details
  process_search();

  # Pre-process license Id, to fetch extra data from ICS
  process_license()
    if $line{license_id};

  # Pre-process content fields, to extract extra data from the journals system
  process_content()
    if $line{issn};

  # Pre-process access fields
  process_access()
    if $line{artid};

  # Build dimensionalized data, and write the fact row
  output_fact();

#last if 5000<
  ++$line_count{Success};
}
print $progress_fh "\n"
  or die "Can't write $progress_fname: $!";
$dbh->rollback
  if $opts{test};

while(my($year,$part)=each %partitions){
  my $fh=$part->{fh};
  close $fh
    or die "Can't close $part->{fname}: $!";
  print $progress_fh "Closed $part->{fname}\n"
    or die "Can't write $progress_fname: $!";
  sleep 2; # Make sure the timestamp is unique
  my $queue_filename=join '.',
    'ejstats',
    $opts{date} || 'nodate',
    $opts{worker},
    time(),
    'dat',
  ;
  my $queue_dir=$opts{'queue-dir'} || "$dir_stats/queue";
  my $queue_name="$queue_dir/$queue_filename";
  my $queue2_name="$dir_stats/queue2/$queue_filename";
  rename $part->{fname},$queue_name
    or die "Can't rename $part->{fname} to $queue_name: $!";
  print $progress_fh "Renamed to $queue_name\n"
    or die "Can't write $progress_fname: $!";
  link $queue_name,$queue2_name
    or die "Can't link $queue2_name to $queue_name: $!";
}

{
  my $proc_time=time()-$start_time;
  my $loaded=join '',
    "Processed lines ($proc_time seconds): ",
    join(', ',map "$_: $line_count{$_}",sort keys %line_count),
    "\n",
  ;
  print $progress_fh $loaded
    or die "Can't write $progress_fname: $!";
  print "\n",$loaded
    if $opts{progress};
}

# Report cache sizes
if($opts{progress}){
  for my $dimension(sort keys %dimensions){
    my $dim=$dimensions{$dimension};
    if(my $mem=$dim->{cache_memory}){
      my $n_keys=keys %$mem;
      print "Dimension $dimension: $n_keys cached\n";
    }elsif(my $cache=$dim->{cache}){
      my $n_keys=$cache->{count};
      my $size='XXX';
      print "Dimension $dimension: $n_keys cached in $size bytes\n";
      print "   hit/miss=$cache->{hits}/$cache->{misses}, purges=$cache->{purges}\n";
    }elsif($dimension eq 'userid'){
      my $n_keys=keys(%$dim)-1;
      print "Dimension $dimension: $n_keys cached\n";
    }
  }
}


# Clear caches to save memory
%identity_by_id=();
%identity_by_key=();
%dimensions=();
print $progress_fh "Caches cleared\n"
  or die "Can't write $progress_fname: $!";

# Update dim_userid and dim_ticket_user
if(!$opts{test} && !$opts{'no-userids'}){
  # Figure out which userids we need to update
  my %userids;
  {
    my $sth=$dbh->prepare(q(
      select userid
      from dim_userid
    ));
    $sth->execute;
    $sth->bind_columns(\my $userid);
    while($sth->fetchrow_arrayref){
      ++$userids{$userid};
    }
  }
  print $progress_fh "Fetched userids\n"
    or die "Can't write $progress_fname: $!";

  # Update user details
  use IOP::Ticket::Common;
  my $dir_backup="$IOP::Ticket::Common::data/backup";
  my $backup_fname=(<$dir_backup/*.ldif>)[-1]
    or die "Can't find LDAP backup filename";
  open my $fh,'<',$backup_fname
    or die "Can't open $backup_fname: $!";
  local $/='';
  my $sth_userid_fetch=$dbh->prepare(q(
    select username
    from dim_userid
    where userid=?
  ));
  my $sth_userid_update=$dbh->prepare(q(
    update dim_userid
    set username=?
    where userid=?
  ));
  my $sth_userid_insert=$dbh->prepare(q(
    insert into dim_userid(username,userid)
    values(?,?)
  ));
  my $sth_user_fetch=$dbh->prepare(q(
    select name
    from dim_ticket_user
    where username=?
  ));
  my $sth_user_update=$dbh->prepare(q(
    update dim_ticket_user
    set name=?
    where username=?
  ));
  my $sth_user_insert=$dbh->prepare(q(
    insert into dim_ticket_user(name,username)
    values(?,?)
  ));
  my $name_len=column_size('dim_ticket_user','name');
  print $progress_fh "Reading users from $backup_fname\n"
    or die "Can't write $progress_fname: $!";
  while(<$fh>){
    /^objectClass: iopPerson/m
      or next;
    my %rec;
    s/\s+\z//;
    pos()=0;
    while(/\G\s*(\w+):(:?)\s+(.*(?:\n\s+.*)*)/gm){
      my($key,$encoded,$val)=($1,$2,$3);
      push @{$rec{$key}||=[]},[$encoded,$val];
    }
    my @userids=map $_->[1],@{$rec{uid} || []}
      or next;
    s/\A0+(?=\d)// for @userids;
    grep delete $userids{$_},@userids
      or next;
    my($cn,$name)=@rec{'cn','displayName'};
    $name||=$cn;
    for($cn,$name){
      my($coded,$val)=@{$_->[0]};
      if($coded){
	$val=decode_base64($val);
	utf8::decode($val);
      }
      $_=$val;
    }
    $cn=lc $cn;

    if($name_len>0 && length($name)>$name_len){
      substr($name,$name_len)='';
    }

    # Create/update the ticket user record
    $sth_user_fetch->execute($cn);
    if(my($old_name)=$sth_user_fetch->fetchrow_array){
      $sth_user_fetch->finish;
      if($old_name ne $name){
	$sth_user_update->execute($name,$cn);
      }
    }else{
      $sth_user_insert->execute($name,$cn);
    }

    # Create/update the userid record
    for my $userid(@userids){
      $sth_userid_fetch->execute($userid);
      if(my($old_cn)=$sth_userid_fetch->fetchrow_array){
	$sth_userid_fetch->finish;
	if(($old_cn || '') ne $cn){
	  $sth_userid_update->execute($cn,$userid);
	}
      }else{
	$sth_userid_insert->execute($cn,$userid);
      }
    }
  }

  # Create dummy records for the remaining users
  print $progress_fh "Creating nulls for remaining users\n"
    or die "Can't write $progress_fname: $!";
  while(my $userid=each %userids){
    $sth_userid_update->execute(undef,$userid)+0
      or $sth_userid_insert->insert(undef,$userid);
  }
  print $progress_fh "Users loaded\n"
    or die "Can't write $progress_fname: $!";
}


# Delete status file if everything went OK
close $progress_fh
  or die "Can't close $progress_fname: $!";
unlink $progress_fname
  or die "Can't unlink $progress_fname: $!";
exit 0;










sub identity_by_id{
  my($idval)=@_;
  defined $idval
    or return undef;

  # We've already seen it during the current load (but it might be undef)
  return $identity_by_id{$idval}
    if exists $identity_by_id{$idval};

  # Fetch it from ICS
  my $record;
  if($idval eq '__UNKNOWN__'){
    $record={
      idval => '__UNKOWN__',
      classification => '__UNKNOWN__',
      share_subs => 0,
      include_identity => bool(1),
    };
  }else{
    my $ident=$rest->identity_read(sess_idval(),$idval)
      or carp("Can't read identity $idval"),
	return $identity_by_id{$idval}=undef;

    # Extract the fields we're actually interested in
    $record=$identity_by_id{$idval}={
      idval => $idval,
      classification => $ident->get_classification,
      country => uc $ident->get('mainAddress.country'),
      share_subs =>
	($ident->get('syndicate.shareSubscriptions') || 'false') eq 'true',
      include_identity => bool($ident->get_include_identity,'notnull'),
    };
  }
  $record->{country_key}=dim_fetch($record->{country},dim => 'country');

  # Make sure it's in the dimension, and up to date
  my $dim=$dimensions{identity}||={};
  my $sth_fetch=$dim->{sth_fetch_by_id}||=$dbh->prepare(q(
    select identity_key
    from dim_identity
    where identity_id=?
  ));
  my $attempted;
  insert_identity: {
    $sth_fetch->execute($idval);
    if(my($key)=$sth_fetch->fetchrow_array){
      $sth_fetch->finish;
      $record->{key}=$key;
      my $sth_update=$dim->{sth_update_by_id}||=$dbh->prepare(q(
	update dim_identity
	set classification=?,
	  include_identity=?,
	  country_key=?
	where identity_key=?
      ));
      $sth_update->execute(
	@$record{'classification','include_identity','country_key','key'}
      );
    }else{
      $key=$record->{key}=seq_next('identity');
      my $sth_insert=$dim->{sth_insert_by_id}||=$dbh->prepare(q(
	insert into dim_identity(identity_key,identity_id,
	  classification,include_identity,country_key
	) values(?,?,
	  ?,?,?
	)
      ));
      eval{
	$sth_insert->execute($key,$idval,
	  @$record{'classification','include_identity','country_key'}
	);
      } or do{
        $attempted++ and die;
	redo insert_identity;
      };
    }
  }
  $identity_by_key{$record->{key}}=$record;

  $record;
}

sub identity_by_key{
  my($key)=@_;
  defined $key
    or return undef;

  return $identity_by_key{$key}
    if exists $identity_by_key{$key};

  # Fetch from the dimension
  my $dim=$dimensions{identity}||={};
  my $sth_fetch=$dim->{sth_fetch_by_key}||=$dbh->prepare(q(
    select identity_id
    from dim_identity
    where identity_key=?
  ));
  $sth_fetch->execute($key);
  my($idval)=$sth_fetch->fetchrow_array
    or warn("Can't find identity key $key!"),
      return $identity_by_key{$key}=undef;

  $sth_fetch->finish;
  return identity_by_id($idval);
}

sub dim_fetch{
  my($value,%dim_opts)=@_;
  my $dimension=$dim_opts{dim};
  if(!defined($value) || $value!~/\S/){
    return undef;
  }elsif($opts{test}){
    my $dim=$dimensions{$dimension}||={};
    my $key=$dim->{cache}{$value}||=seq_next($dimension);
    return "$key($value)";
  }else{
    # Really fetch it from a dimension lookup table
    my $dim=$dimensions{$dimension}||={};
    my $max_len=$dim->{max_length}
      ||=column_size("dim_${dimension}",$dim->{col_val} || $dimension);
    if($max_len>0 && length($value)>$max_len){
      substr($value,$max_len)='';
    }
    if($dim->{cache_opts}){
      my $cache=$dim->{cache}||=cache_new($dimension,$dim);
      if(my $key=$cache->get($value)){
	return ($key,1) if $dim_opts{check_exists};
        return $key;
      }
    }elsif(my $key=$dim->{cache_memory} && $dim->{cache_memory}{$value}){
      return ($key,1) if $dim_opts{check_exists};
      return $key;
    }
    my $sth_fetch=$dim->{sth_fetch}||=do{
      my $col_val=$dim->{col_val} || $dimension;
      $dbh->prepare($dim->{sql_fetch} || qq(
	select ${dimension}_key
	from dim_${dimension}
	where $col_val=?
      ));
    };

    my $normal_value=$value;
    if(my $sub=$dim->{sub_normalize}){
      $normal_value=$sub->($dim,$normal_value);
      defined($normal_value) && $normal_value=~/\S/
        or return undef;
    }

    my($key,$attempted,$exists);
    get_key: {
      $sth_fetch->execute($normal_value);
      if(($key)=$sth_fetch->fetchrow_array){
	$sth_fetch->finish;
	++$exists;
      }else{
	# Generate a new dimension record
	$key=seq_next($dimension);
	eval{
	  if(my $sub=$dim->{sub_insert}){
	    $sub->($dim,$key,$normal_value);
	  }else{
	    my $sth_insert=$dim->{sth_insert}||=do{
	      my $col_val=$dim->{col_val} || $dimension;
	      $dbh->prepare($dim->{sql_insert} || qq(
		insert into dim_${dimension}(${dimension}_key,$col_val)
		values(?,?)
	      ));
	    };
	    $sth_insert->execute($key,$normal_value);
	  }
	  1;
	} or do{
	  $attempted++ and die;
	  redo get_key;
	};
      }
    }
    if(my $cache=$dim->{cache_memory}){
      $cache->{$value}=$key;
    }elsif($cache=$dim->{cache}){
      $cache->set($value,$key);
    }

    return ($key,$exists) if $dim_opts{check_exists};
    return $key;
  }
}

sub bool($;$){
  my($value,$notnull)=@_;
  if($value){
    return 1;
  }elsif(defined($value) || $notnull){
    return 0;
  }else{
    return undef;
  }
}

{
  my %seq;

  sub seq_next{
    my($name,$increment)=@_;
    if($opts{test}){
      return ++$seq{$name};
    }else{
      my $seq=$seq{$name}||={};
     
      my $sth_next=$seq->{sth_next}||=$dbh->prepare(qq(
        SELECT NEXT VALUE FOR seq_$name
      ));
      # XXX This doesn't increment the sequence by X, it changes the normal increment to X. This is a potential race condition
      if($increment){
        if($seq->{increment} && --$seq->{increment}){
	  return ++$seq->{next};
	}
	 print "sql_cols:col_name:---", Dumper($name);
	my $sth_inc=$seq->{sth_inc}||=$dbh->prepare(qq(
	  
           ALTER SEQUENCE seq_$name INCREMENT BY $increment MINVALUE 1 MAXVALUE 999999999999999999999999999 NO CYCLE CACHE 20 ;

	));
	$sth_inc->execute;
	$seq->{increment}=$increment-1;
	$sth_next->execute;
	my($val)=$sth_next->fetchrow_array;
	$sth_next->finish;
	return($seq->{next}=$val-$increment+1);
      }
      $sth_next->execute;
      my($val)=$sth_next->fetchrow_array;
      $sth_next->finish;
      return $val;
    }
  }

  sub seq_reset{
    %seq=();
  }
}

{
  my $sess_idval;

  sub sess_idval{
    if($sess_idval && $rest->session_is_active($sess_idval)){
      return $sess_idval;
    }
    $sess_idval=$rest->authenticate;
  }
}

{
  my %column_size;
  sub column_size{
    my($table,$column)=@_;
    if(my $size=$column_size{$table,$column}){
      return $size;
    }
    my $sth=$dbh->column_info(undef,undef,uc($table),uc($column));
    $sth->execute;
    my $max_len=-1;
    if(my $row=$sth->fetchrow_hashref){
      if($row->{TYPE_NAME}=~/CHAR/){
	$max_len=$row->{COLUMN_SIZE};
	$max_len/=2 if $row->{TYPE_NAME}=~/NVAR/;
      }
      $sth->finish;
    }
    $max_len;
  }
}



# Pre-process identities, to figure out the primary
sub process_identities{
  my @idvals=split ',',$line{identity_ids};
  if(my $sess_idval=$line{ics_session_id}){
    my $dim_si=$dimensions{session_identity}||={};
    my $dim_s=$dimensions{ics_session}||={};
    my $cache_s=$dim_s->{cache}||=cache_new(ics_session => $dim_s);
    if(my $val=$cache_s->get($sess_idval)){
      # We've already cached it
      @line{qw(
        ics_session_key identity_key_primary include_identity country_key_inst
	syndicategroup_key
      )}=map $_ eq '' ? undef : $_,split '/',$val;
    }else{
      # See if we've recorded this session in the database already
      my $sth_fetch=$dim_si->{sth_fetch}||=$dbh->prepare(q(
	select ics_session_key,identity_key_primary,
	  include_identity,country_key,syndicategroup_key
	from dim_ics_session,dim_identity
	where ics_session_id=?
	  and identity_key=identity_key_primary
      ));
      my $attempted;
      insert_session: {
	$sth_fetch->execute($sess_idval);
	if(
	  @line{qw(
	    ics_session_key identity_key_primary include_identity
	    country_key_inst syndicategroup_key
	  )}=$sth_fetch->fetchrow_array
	){
	  # We've read it from the database, so no need to do anything else
	  $sth_fetch->finish;
	}else{
	  # This is a completely unseen session, so build the database records
	  my $cache_key=join ' ',(@idvals=sort @idvals);
	  my $cache=$dim_si->{cache}||=cache_new(session_identity => $dim_si);
	  my $sth_insert_session=$dim_si->{sth_insert_session}
	    ||=$dbh->prepare(q(
	      insert into dim_ics_session(ics_session_key,ics_session_id,
		identity_key_primary,syndicategroup_key
	      )
	      values(?,?,?,?)
	    ));
	  my $sth_insert_sess_ident=$dim_si->{sth_insert_sess_ident}
	    ||=$dbh->prepare(q(
	      insert into dim_session_identity(
		ics_session_key,identity_key,participation_type
	      )
	      values(?,?,?)
	    ));
	  my $session_key=$line{ics_session_key}=seq_next('ics_session',1000);

	  if(my $cache_value=$cache->get($cache_key)){
	    # This bunch of identities has been cached today, so create records
	    eval{
	      $sth_insert_session->execute(
		$session_key,$sess_idval,$cache_value->{identity_key_primary},
		$cache_value->{syndicategroup_key},
	      );
	    } or do{
	      $attempted++ and die;
	      redo insert_session;
	    };
	    $line{$_}=$cache_value->{$_} for qw(
	      identity_key_primary include_identity country_key_inst
	      syndicategroup_key
	    );
	    for(@{$cache_value->{session_identity}||[]}){
	      $sth_insert_sess_ident->execute($session_key,@$_);
	    }
	  }else{
	    # Work out the participation type of each identity, esp. the primary

	    my $primary_idval=$line{identity_id_primary};

	    # Fetch identity properties
	    my(%idents,@syndicategroup);
	    for my $idval(@idvals){
	      my $identity=identity_by_id($idval)
		or next;
	      next if $idents{$idval};
	      $idents{$idval}={
	        identity => $identity,
		class => $identity->{classification},
		key => $identity->{key},
		depth => 0,
	      };
	      push @syndicategroup,$identity->{key}
	        if $identity->{classification} eq 'consortium';
	    }
	    @idvals=keys %idents;

	    my %cache_value;

            if($primary_idval){
	      # We already know the primary,
	      # so all we have to do is identify the shared identities
	      inherited_loop:
	      for my $idval(@idvals){
	        next if $idval eq $primary_idval;
		my $rec=$idents{$idval};
		$rec->{class} eq 'institution'
		  or next;
                my $paths=$rest->identity_read_paths(sess_idval(),$idval)
		  or next;
		for my $path(@{$paths->get_paths}){
		  grep $_ eq $primary_idval,@$path
		    or next;
		  ++$rec->{ignore};
		  last;
		}
	      }
	    }else{
	      # XXX This can be chucked once we're always logging the primary Id
	      # Work out child/parent relationships
	      while(my($idval,$rec)=each %idents){
		next
		  if $rec->{children}		# We've already seen this one
		  || $rec->{class} eq 'hierarchy'	# These must have children
		;
		my $paths=$rest->identity_read_paths(sess_idval(),$idval) or next;
		for my $path(@{$paths->get_paths}){
		  my $child;
		  while(my $parent=shift @$path){
		    my $depth=@$path+1;
		    if(my $parent_rec=$idents{$parent}){
		      $parent_rec->{depth}=$depth if $depth>$parent_rec->{depth};
		      ++$parent_rec->{children}{$child} if $child;
		    }
		    if(my $child_rec=$child && $idents{$child}){
		      ++$child_rec->{parents}{$parent};
		    }
		    $child=$parent;
		  }
		}
	      }
	      while(my($idval,$record)=each %idents){
		for(qw(children parents)){
		  my $ref=$record->{$_} or next;
		  $record->{$_}=[keys %$ref];
		}
	      }

	      # Find group members and individual hierarchies
	      my(@stack_group,@stack_indiv);
	      while(my($idval,$record)=each %idents){
		if($record->{class} eq 'institution'
		&& $record->{identity}{share_subs}
		){
		  ++$record->{is_group};
		  push @stack_group,@{$record->{children} || []};
		}elsif($record->{class} eq 'individual'){
		  push @stack_indiv,@{$record->{parents} || []};
		}
	      }
	      # Mark group members as ignored
	      while(my $idval=pop @stack_group){
		my $rec=$idents{$idval} or next;
		next if $rec->{ignore};
		++$rec->{ignore};
		push @stack_group,@{$rec->{children} || []};
	      }
	      # Mark individual hierarchies as ignored
	      while(my $idval=pop @stack_indiv){
		my $rec=$idents{$idval} or next;
		next if $rec->{is_group} || $rec->{ignore_parent};
		++$rec->{ignore_parent};
		push @stack_indiv,@{$rec->{parents} || []};
	      }

	      # Force guest to be least specific
	      if(my $record=$idents{guest}){
		$record->{depth}=-1;
	      }

	      # Go through the institutions, and pick out the deepest
	      my $max= -999;
	      while(my($idval,$record)=each %idents){
		next
		  if $record->{ignore}                    # group member
		  || $record->{ignore_parent}             # ancestor of individual
		  || $record->{class} eq 'hierarchy'      # hierarchy-only node
		  || $record->{class} eq 'individual'     # individual identity
		  || (my $depth=$record->{depth}) < $max  # not deep enough
		;
		$max=$depth;
		$primary_idval=$idval;
	      }
	      $primary_idval||='guest';
	    }
	    my $primary_ident=identity_by_id($primary_idval)
	      or warn("No record saved for primary identity $primary_idval\n"),
		next LINE;

	    # Fetch/create the syndicate group record
	    my $syndicategroup_key;
	    if(@syndicategroup=sort { $a <=> $b } @syndicategroup){
	      my $groupval=join ',',@syndicategroup;
	      ($syndicategroup_key,my $exists)=dim_fetch($groupval,
	        dim => 'syndicategroup',
		check_exists => 1,
	      );
	      if(!$exists){
	        my $sth=$dim_s->{sth_insert_group}||=$dbh->prepare(q(
		  insert into dim_syndicategroup_identity(
		    syndicategroup_key,identity_key
		  ) values(?,?)
		));
		$sth->execute($syndicategroup_key,$_)
		  for @syndicategroup;
	      }
	    }
	    
	    # Create the session record
	    eval{
	      $sth_insert_session->execute($session_key,$sess_idval,
		$line{identity_key_primary}=$cache_value{identity_key_primary}
		  =$primary_ident->{key},
		$line{syndicategroup_key}=$cache_value{syndicategroup_key}
		  =$syndicategroup_key
	      );
	    } or do{
	      $attempted++ and die;
	      redo insert_session;
	    };
	    $line{country_key_inst}=$cache_value{country_key_inst}
	      =$primary_ident->{country_key};
	    $line{include_identity}=$cache_value{include_identity}
	      =$primary_ident->{include_identity};
	    
	    # Create the session participation records
	    for my $idval(@idvals){
	      my $record=$idents{$idval} or next;
	      my $type;
	      if($idval eq $primary_idval){
		$type='primary';
	      }elsif($record->{ignore}){
		$type='shared';
	      }elsif($record->{class} eq 'individual'){
		$type='individual';
	      }else{
		$type='inherited';
	      }
	      $sth_insert_sess_ident->execute(
		$session_key,$record->{key},$type
	      );
	      push @{$cache_value{session_identity}||=[]},[$record->{key},$type];
	    }
	    $cache->set($cache_key,\%cache_value);
	  }
	}
      }
      $cache_s->set($sess_idval,join '/',map defined() ? $_ : '',@line{qw(
	ics_session_key identity_key_primary include_identity country_key_inst
	syndicategroup_key
      )});
    }
  }elsif(my $primary_idval=$line{identity_id_primary}){
    my $primary_ident=identity_by_id($primary_idval)
      or warn("No record saved for primary identity $primary_idval\n"),
	next LINE;
    @line{'identity_key_primary','country_key_inst','include_identity'}
      =@$primary_ident{'key','country_key','include_identity'};
  }else{
    # XXX No session Id. Should we make one up??
  }
}

# Pre-process license Id, to fetch extra data from ICS
sub process_license{
  my $lic_idval=$line{license_id};
  my $dim=$dimensions{license}||={};
  my $sth_select=$dim->{sth_fetch_license}||=$dbh->prepare(q(
    select license_key,identity_key
    from dim_license
    where license_id=?
  ));
  my $sth_insert=$dim->{sth_insert_license}||=$dbh->prepare(q(
    insert into dim_license(license_key,license_id,
      subscription_id,product_id,identity_key)
    values(?,?,
      ?,?,?
    )
  ));
  my $attempted;
  insert_license: {
    $sth_select->execute($lic_idval);
    if(my($lic_key,$ident_key)=$sth_select->fetchrow_array){
      # We've already seen it
      $sth_select->finish;
      $line{license_key}=$lic_key;
      $line{identity_key_license}=$ident_key;
    }elsif(my $license=$rest->license_read(sess_idval(),$lic_idval)){
      # We haven't seen it before, but we can read it from ICS
      my $lic_key=$line{license_key}=seq_next('license');
      my $ident_idval=$line{identity_id_license}=$license->get_identity_idval;
      my $identity=identity_by_id($ident_idval)
	or warn("Can't find licensed identity $ident_idval for license $lic_idval"),
	  next LINE;
      my $ident_key=$line{identity_key_license}=$identity->{key};
      my $sub_idval=$license->get_subscription_idval;
      my $sub=$rest->subscription_read(sess_idval(),$sub_idval)
        or warn("Can't find subscription $sub_idval for license $lic_idval"),
	  next LINE;
      eval{
	$sth_insert->execute($lic_key,$lic_idval,
	  $sub_idval,$sub->get_product_idval,$ident_key
	);
      } or do{
        $attempted++ and die;
	redo insert_license;
      };
    }else{
      # It doesn't exist in ICS
      # This happens a lot on dev, where there are multiple ICS servers
      my $lic_key=$line{license_key}=seq_next('license');
      my $ident_key=$line{identity_key_license}
	=dim_fetch('__UNKNOWN__',dim => 'identity');
      eval{
	$sth_insert->execute($lic_key,$lic_idval,
	  '__UNKNOWN__','__UNKNOWN__',$ident_key
	);
      } or do{
        $attempted++ and die;
	redo insert_license;
      };
    }
  }
}

# Pre-process external authentication details, to generate external_authen_key
sub process_external_auth{
  my $ext_auth_service=$line{ext_auth_service}
    and my $ext_auth_id=$line{ext_auth_id}
    or return;
  my $dim=$dimensions{external_authen}||={};
  my $cache=$dim->{cache}||=cache_new(external_auth => $dim);
  my $cache_key=join $;,$ext_auth_service,$ext_auth_id;
  my $max_length=$dim->{max_length}
    ||=column_size('dim_external_authen','authen_service')
      +column_size('dim_external_authen','authen_id');
  if(length($cache_key)>$max_length){
    substr($cache_key,$max_length)='';
  }

  if(my $key=$cache->get($cache_key)){
    $line{external_authen_key}=$key;
    return;
  }

  my $sth_select=$dim->{sth_select}||=$dbh->prepare(q(
    select external_authen_key
    from dim_external_authen
    where authen_service=? and authen_id=?
  ));
  my($attempted,$key);
  insert_external_auth: {
    $sth_select->execute($ext_auth_service,$ext_auth_id);
    if(($key)=$sth_select->fetchrow_array){
      $line{external_authen_key}=$key;
    }else{
      $line{external_authen_key}=$key=seq_next('external_authen');
      my $sth_insert=$dim->{sth_insert}||=$dbh->prepare(q(
	insert into dim_external_authen(
	  external_authen_key,authen_service,authen_id
	)
	values(?,?,?)
      ));
      eval{
	$sth_insert->execute($key,$ext_auth_service,$ext_auth_id);
      } or do{
        $attempted++ and die;
	redo insert_external_auth;
      };
    }
  }

  $cache->set($cache_key,$key);
  $key;
}

# Pre-process search queries, to generate search key
sub process_search{
  grep defined() && /\S/,
    my($search_query,$search_field,$search_within)
      =@line{'search_query','search_field','search_within'}
    or return;
  my $dim=$dimensions{search}||={};
  my $cache=$dim->{cache}||=cache_new(search => $dim);

  # Normalise components
  for(
    [\$search_query,4000],
    [\$search_field,400],
    [\$search_within,400],
  ){
    my($ref,$length)=@$_;
    defined $$ref or $$ref='';
    $$ref=~s/\s+/ /g;
    $$ref=~s/\A\s//;
    $$ref=~s/\s\z//;
    $$ref=' ' if $$ref eq '';
    chop($$ref)
      while bytes::length($$ref)>$length;
  }

  # Fetch from the cache if we already have it
  my $cache_key=join $;,$search_query,$search_field,$search_within;
  if(my $key=$cache->get($cache_key)){
    $line{search_key}=$key;
    return;
  }

  # Fetch from the db if we don't
  my $sth_select=$dim->{sth_select}||=$dbh->prepare(q(
    select search_key
    from dim_search
    where search_query=? and search_field=? and search_within=?
  ));
  my($attempted,$key);
  insert_search: {
    $sth_select->execute($search_query,$search_field,$search_within);
    if(($key)=$sth_select->fetchrow_array){
      $line{search_key}=$key;
      $sth_select->finish;
    }else{
      $line{search_key}=$key=seq_next('search');
      my $sth_insert=$dim->{sth_insert}||=$dbh->prepare(q(
	insert into dim_search(
	  search_key,search_query,search_field,search_within
	)
	values(?,?,?,?)
      ));
      eval{
	$sth_insert->execute($key,$search_query,$search_field,$search_within)
      } or do{
        $attempted++ and die;
	redo insert_search;
      };
    }
  }

  $cache->set($cache_key,$key);
  $key;
}



# Pre-process content fields, to extract extra data from the journals system
sub process_content{
  my $issn=$line{issn}
    or return;
  my $dim=$dimensions{content_item}||={};
  my $cache=$dim->{cache}||=cache_new(content_item => $dim);

  my @content_item=$issn;
  for my $col(qw(volnum issnum artnum)){
    defined(my $val=$line{$col}) or last;
    push @content_item,$val;
  }
  my $content_item=join '/',@content_item;
  my $max_length=$dim->{max_length}
    ||=column_size('dim_content_item','content_item');
  if(length($content_item)>$max_length){
    substr($content_item,$max_length)='';
  }
  if(my $val=$cache->get($content_item)){
    @line{qw(content_item_key online_date free_reason_code age_years age_days)}
      =split '/',$val;
    $line{artid}=$content_item
      if $line{online_date};
    return;
  }

  my $sth_select=$dim->{sth_select_wide}||=$dbh->prepare(q(
    select content_item_key,online_date
    from dim_content_item
    where content_item=?
  ));
  my($attempted,$key);
  insert_content: {
    $sth_select->execute($content_item);
    my($online_date);
    if(($key,$online_date)=$sth_select->fetchrow_array){
      $line{content_item_key}=$key;
      if($online_date){
	# We've already recorded an online date
	$line{artid}=$content_item;
	$line{online_date}=$online_date;
      }elsif(!grep(!defined(),my @parts=@line{qw(issn volnum issnum artnum)})){
	# There's no online date, but it is an article-level item
	# Check to see whether it's been released since we last saw it
        my $artid=join '/',@parts;
	if(my $article=$model_test->article_read_id($artid)){
	  my $issn=$article->issn;
	  my $volnum=$article->volnum_phys;
	  my $issnum=$article->issnum_phys;
	  my $artnum=$article->artnum;
	  if(not $online_date=$article->date_online(no_default => 1)
	  and $article->is_test
	  and my $article_live=$model_live->article_read_id($artid)
	  ){
	    $article=$article_live;
	    $online_date=$article->date_online(no_default => 1);
	  }
	  my $cover_date=$article->date_cover;
          sanitise_date($cover_date);
	  my $article_type=$article->article_type;
          my $ecs=$model_test->_xml_parse($article->xml,'ecs')->[0];
          $ecs&&=$ecs->{__content__};
          if(defined $ecs){
            $ecs=~s/\A\s+//;
            $ecs=~s/\s+\z//;
            undef $ecs if $ecs eq '';
          }
          my $title=$article->title_plain;
          my $authors=$article->authors_plain;
          for($title,$authors){
            substr($_,2000)=''
              if defined() && length()>2000;
          }

	  # Update the dimension table
	  my $sth_update=$dim->{sth_update_wide}||=$dbh->prepare(q(
	    update dim_content_item
	    set
	      issn=?,volnum=?,issnum=?,artnum=?,
	      cover_date=?,online_date=?,article_type=?,
              ecs=?,title=?,authors=?
	    where content_item_key=?
	  ));
	  $sth_update->execute(
	    $issn,$volnum,$issnum,$artnum,
	    $cover_date,$online_date,$article_type,
            $ecs,$title,$authors,
	    $key,
	  );

	  $line{artid}=$artid;
	  $line{online_date}=$online_date;
	}
      }else{
        # No online date, and not at article level
      }
    }else{
      $line{content_item_key}=$key=seq_next('content_item');
      my($volnum,$issnum,$artnum,$cdate,$atype,$fname,$sname,$ecs,$title,$authors);
      if(my $journal=$model_test->journal_read($issn)){
	$fname=$journal->name_full;
	$sname=$journal->name_short;
	if(defined($volnum=$line{volnum})){
	  if(my $vol=$journal->volume_read($volnum)){
	    $volnum=$vol->volnum_phys;
	    if(defined($issnum=$line{issnum})){
	      if(my $iss=$vol->issue_read($issnum)){
		$issnum=$iss->issnum_phys;
		if(defined($artnum=$line{artnum})){
		  if(my $article=$iss->article_read_artnum($artnum)){
		    $cdate=$article->date_cover;
                    sanitise_date($cdate);
		    if(not $online_date=$article->date_online(no_default => 1)
		    and $article->is_test
		    and my $article_live
		      =$model_live->article_read_id($content_item)
		    ){
		      $online_date=$article->date_online(no_default => 1);
		    }
		    $line{online_date}=$online_date;
		    $atype=$article->article_type;
		    $line{artid}=$content_item;

		    $ecs=$model_test->_xml_parse($article->xml,'ecs')->[0];
		    $ecs&&=$ecs->{__content__};
		    if(defined $ecs){
		      $ecs=~s/\A\s+//;
		      $ecs=~s/\s+\z//;
		      undef $ecs if $ecs eq '';
		    }

		    $title=$article->title_plain;
		    $authors=$article->authors_plain;
		    for($title,$authors){
		      substr($_,2000)=''
		        if defined() && length()>2000;
		    }
		  }else{
		    $artnum='__UNKNOWN__';
		  }
		}
	      }else{
		$issnum='__UNKNOWN__';
	      }
	    }
	  }else{
	    $volnum='__UNKNOWN__';
	  }
	}
      }else{
	$issn='__UNKNOWN__';
	$fname='__UNKNOWN__';
	$sname='__UNKNOWN__';
      }
      $volnum='__UNKNOWN__'
	if @content_item>=2 && !defined $volnum;
      $issnum='__UNKNOWN__'
	if @content_item>=3 && !defined $issnum;
      $artnum='__UNKNOWN__'
	if @content_item>=4 && !defined $artnum;

      my $sth_insert=$dim->{sth_insert_wide}||=$dbh->prepare(q(
	insert into dim_content_item(content_item_key,content_item,
	  issn,volnum,issnum,artnum,
	  cover_date,online_date,article_type,
	  journal_name_full,journal_name_short,
	  ecs,title,authors
	)
	values(?,?,
	  ?,?,?,?,
	  convert(date,?),convert(date,?),?,
	  ?,?,
	  ?,?,?
	)
      ));
      eval{
	$sth_insert->execute($key,$content_item,
	  $issn,$volnum,$issnum,$artnum,
	  $cdate,$online_date,$atype,
	  $fname,$sname,
	  $ecs,$title,$authors,
	);
      } or do{
        $attempted++ and die;
	redo insert_content;
      };
    }
  }

  my($free_reason_code,$age_years,$age_days);
  if($line{online_date} and my $artid=$line{artid}){
    my $sth=$dim->{sth_fetch_freebie}||=$jdbh->prepare(q(
      select free_reason
      from jnl_free_history,jnl_free_reasons
      where free_item=?
	and ?::date between coalesce(free_start,'0001-01-01')
	  and coalesce(free_end,'9999-12-31')
	and free_reason=reason_reason
      order by reason_priority desc
      limit 1
    ));

    while($artid=~m#/#){
      $sth->execute($artid,$line{date});
      if(($free_reason_code)=$sth->fetchrow_array){
	$sth->finish;
	last;
      }else{
	$artid=~s#/[^/]*\z##;
      }
    }
    my($online_year,$online_month,$online_day)=split /-0?/,$line{online_date};
    my($access_year,$access_month,$access_day)=split /-0?/,$line{date};
    $age_years=$access_year-$online_year;
    $age_days=Delta_Days($online_year,$online_month,$online_day,
      $access_year,$access_month,$access_day);
  }
  $cache->set($content_item,my $val=join '/',map defined() ? $_ : '',
    $key,$line{online_date},$free_reason_code,$age_years,$age_days);
  @line{qw(free_reason_code age_years age_days)}
    =($free_reason_code,$age_years,$age_days);
}

# Make sure the supplied date is sane, modifying in place if necessary
sub sanitise_date{
  my($date)=@_;
  my $orig_date=$date;
  my $sth||=$jdbh->prepare(q(
    select ?::date
  ));

  # We work on the assumption that invalid dates only come from test data,
  # and will be corrected upon release, so we don't need to work terribly hard
  # to get the exact date right, just something reasonably close
  if(my($y,$m,$d)=$date=~/\A(\d\d\d\d)-(\d\d?)-(\d\d?)\z/){
    # Valid format, check the individual fields
    $y>=1000 && $y<=3000
      or $y=$model_live->today_year;

    $m=~s/\A0//;
    $m>=1
      or $m=1;
    $m<=12
      or $m=12;

    $m=~s/\A0//;
    $d||=1;
    $d<=31
      or $d=31;

    # Check it's really a valid date, decrementing the day until it's OK
    while($d>=28){
      $date=sprintf '%04d-%02d-%02d',$y,$m,$d;
      eval{ $jdbh->selectrow_arrayref($sth,{},$date); }
        and last;
      warn "Normalizing dodgy date $orig_date to $date\n";
      --$d;
    }
  }else{
    # Invalid format
    $date=$model_live->today;
  }
  $_[0]=$date;
}

# Pre-process access fields
sub process_access{
  my $dim=$dimensions{access}||={};

  # Figure out access role, based on the type of the licensed identity
  my $access_role='__UNKNOWN__';
  if(my $ident=identity_by_key($line{identity_key_license})){
    my $class=$ident->{classification};
    my $idval=$ident->{idval};
    $access_role
      = !defined($class) ? '__UNKNOWN__'
      : $class eq 'individual' || $idval eq 'IOP-IND' ? 'individual'
      : $class eq 'hierarchy' || $idval eq 'guest' ? 'free'
      : $class eq 'consortium' || $class eq 'network' ? 'consortium'
      : 'institution'
    ;
  }elsif(($line{http_status} || '200')!~/\A[23]/){
    $access_role='no licence';
  }elsif("@line{'date','time'}" lt '2007-10-03 09:26:13'){
    $access_role='licence not recorded';
  }else{
    $access_role='licence not checked';
  }

  # Check for a freebie
  my $free_reason_code=$line{free_reason_code};
  if($access_role eq 'free' && !$free_reason_code
  and my $lic_idval=$line{license_id}
  ){
    # Distinguish between free accesses which aren't due to freebies
    # It's OK to cache these in memory, because there aren't many of them
    my $cache=$dim->{license_cache}||={};
    if(exists $cache->{$lic_idval}){
      $free_reason_code=$cache->{$lic_idval};
    }else{
      if(my $license=$rest->license_read(sess_idval(),$lic_idval)){
	my $sub_idval=$license->get_subscription_idval;
	if(my $sub=$rest->subscription_read(sess_idval(),$sub_idval)){
	  my $prod_idval=$sub->get_product_idval;
	  if(my $prod=$rest->product_read(sess_idval(),$prod_idval)){
	    my $name=$prod->get('name');
	    if($name=~/free journal/i){
	      $free_reason_code=$name=~/secret|hidden/i ? 'X' : 'J';
	    }
	  }
	}
      }
      $cache->{$lic_idval}=$free_reason_code;
    }
  }
  my $free_reason_name;
  if($free_reason_code){
    my $codes=$dim->{free_reasons}||=do{
      my $sth=$jdbh->prepare(q(
        select reason_reason,reason_description
	from jnl_free_reasons
      ));
      $sth->execute;
      my %codes;
      while(my($k,$v)=$sth->fetchrow_array){
        $codes{$k}=$v;
      }
      \%codes;
    };
    $free_reason_name=$codes->{$free_reason_code};
  }

  # Get collection
  my $collection_code=$line{collection_id}
    || $line{service} eq 'Select' && 'select';
  my $collection_name=$collections{$collection_code || ''};

  # Calculate date differences
  my $age_years=$line{age_years};
  my $age_days=$line{age_days};

  # Fetch/insert the record
  $line{_access_values}=[
    $access_role,
    $free_reason_code,$free_reason_name,
    $collection_code,$collection_name,
    $age_years,$age_days
  ];
  $line{access_key}=dim_fetch(join('/',map defined() ? $_ : '',
    $access_role,$free_reason_code,$collection_code,$age_years,$age_days
  ),dim => 'access');
}

# Build dimensionalized data, and write the fact row
sub output_fact{
  # Make sure we've got a suitable partition and corresponding SQL*Loader file
  my $fh;
  {
    my($year)=($line{year})=$line{date}=~/\A(\d\d\d\d)/;
    if(my $out=$partitions{$year}){
      $fh=$out->{fh};
    }else{
      # Make sure the appropriate partition exists
      # XXX This isn't enabled on our server, so we can't do it yet

      my $fname="$dir_stats/ejstats-$opts{worker}.$year.dat";
      open $fh,'>',$fname
        or die "Can't open $fname: $!";
      (my $header=$sql_header)=~s/\$year/$year/;
      print $fh $header
        or die "Can't write $fname: $!";
      $partitions{$year}={
        fname => $fname,
	fh => $fh,
      };
    }
  }

  my @row;
  for(@fact_cols){
    my($col_name,$proc_type,@col_opts)=@$_;
    my $val;
    if($proc_type eq 'dim'){
      (my $line_col=$col_name)=~s/_key\z//;
      if(my %col_opts=@col_opts){
	if(my $col=$col_opts{col}){
	  $val=$line{$col};
	}else{
	  $val=$line{$line_col};
	}
      }else{
        $val=$line{$line_col};
      }
      $val=dim_fetch($val,dim => $line_col,@col_opts);
    }elsif($proc_type eq 'seq'){
      (my $seq=$col_name)=~s/_key\z//;
      $val=seq_next($seq,@col_opts);
    }elsif($proc_type eq 'sub'){
      my($sub)=@col_opts;
      $val=$sub->(\%line);
    }elsif($proc_type eq 'col'){
      $val=$line{$col_name};
    }else{
      die "Unknown processing type: $proc_type";
    }
    push @row,$val;
  }

  if($opts{test}){
    defined or $_='<null>' for my @print_row=@row;
    print "@print_row\n";
  }else{
    for(@row){
      defined
        or $_='',next;
      s/([\\"',])/\\$1/g
        and $_=qq("$_");
    }
    print $fh join(',',@row),"\n"
      or die "Can't write: $!";
  }
}

sub cache_new{
  my($dim_name,$opts)=@_;
  Cache::Numbered->new(%{$opts->{cache_opts} || {}});
}


