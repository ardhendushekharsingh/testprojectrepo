#
# Sonar, entreprise quality control tool.
# Copyright (C) 2008-2012 SonarSource
# mailto:contact AT sonarsource DOT com
#
# Sonar is free software; you can redistribute it and/or
# modify it under the terms of the GNU Lesser General Public
# License as published by the Free Software Foundation; either
# version 3 of the License, or (at your option) any later version.
#
# Sonar is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
# Lesser General Public License for more details.
#
# You should have received a copy of the GNU Lesser General Public
# License along with Sonar; if not, write to the Free Software
# Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA  02
#

# Since 3.4
class BatchBootstrapController < Api::ApiController

  # SONAR-4211 Access to index should not require authentication
  skip_before_filter :check_authentication, :only => 'index'

  # GET /batch_bootstrap/db?project=<key or id>
  def db
    require_parameters :project
    project = load_project()
    db_content = java_facade.createDatabaseForDryRun(project ? project.id : nil)

    send_data String.from_java_bytes(db_content)
  end

  # GET /batch_bootstrap/properties?project=<key or id>
  def properties
    json_properties=Property.find(:all, :conditions => ['user_id is null and resource_id is null']).map { |property| to_json_property(property) }

    root_project = load_project()
    if root_project
      properties = Property.find(:all, :conditions => ["user_id is null and resource_id in (select id from projects where enabled=? and (root_id=? or id=?))", true, root_project.id, root_project.id])
      resource_ids = properties.map{|p| p.resource_id}.uniq.compact
      unless resource_ids.empty?
        resource_key_by_id = Project.find(:all, :select => 'id,kee', :conditions => {:id => resource_ids}).inject({}) {|hash, resource| hash[resource.id]=resource.key; hash}
        properties.each do |property|
          json_properties << to_json_property(property, resource_key_by_id[property.resource_id])
        end
      end
    end

    has_user_role=has_role?(:user, root_project)
    has_admin_role=has_role?(:admin, root_project)
    json_properties=json_properties.select { |prop| allowed?(prop[:k], has_user_role, has_admin_role) }

    render :json => JSON(json_properties)
  end

  # GET /batch_bootstrap/index
  def index
    redirect_to ApplicationController.root_context.to_s + "/deploy/bootstrap/index.txt"
  end

  private

  def load_project
    project = Project.by_key(params[:project])
    return access_denied if project && !has_role?(:user, project)
    project
  end

  def to_json_property(property, project_key=nil)
    hash={:k => property.key, :v => property.text_value.to_s}
    hash[:p]=project_key if project_key
    hash
  end

  def allowed?(property_key, has_user_role, has_admin_role)
    if property_key.end_with?('.secured')
      property_key.include?('.license') ? has_user_role : has_admin_role
    else
      true
    end
  end
end
