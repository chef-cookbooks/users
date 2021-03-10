#
# Cookbook:: users
# Resources:: manage
#
# Copyright:: 2011-2017, Eric G. Wolfe
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#

# :data_bag is the object to search
# :search_group is the groups name to search for, defaults to resource name
# :group_name is the string name of the group to create, defaults to resource name
# :group_id is the numeric id of the group to create, default is to allow the OS to pick next
# :cookbook is the name of the cookbook that the authorized_keys template should be found in
property :data_bag, String, default: 'users'
property :search_group, String, name_property: true
property :group_name, String, name_property: true
property :group_id, Integer
property :cookbook, String, default: 'users'
property :manage_nfs_home_dirs, [true, false], default: true

action :create do
  users_groups = {}
  users_groups[new_resource.group_name] = []

  search(new_resource.data_bag, "groups:#{new_resource.search_group} AND NOT action:remove") do |u|
    u['username'] ||= u['id']
    u['groups'].each do |g|
      users_groups[g] = [] unless users_groups.key?(g)
      users_groups[g] << u['username']
    end

    # Set home to location in data bag,
    # or a reasonable default ($home_basedir/$user).
    home_dir = (u['home'] || "#{home_basedir}/#{u['username']}")

    # check whether home dir is null
    manage_home = !(home_dir == '/dev/null')

    # The user block will fail if the group does not yet exist.
    # See the -g option limitations in man 8 useradd for an explanation.
    # This should correct that without breaking functionality.
    group u['username'] do
      if platform_family?('mac_os_x')
        gid validate_id(u['gid']) unless gid_used?(validate_id(u['gid'])) || new_resource.group_name == u['username']
      else
        gid validate_id(u['gid'])
      end
      only_if { u['gid'] && u['gid'].is_a?(Numeric) }
    end

    # Create user object.
    # Do NOT try to manage null home directories.
    user u['username'] do
      uid validate_id(u['uid']) unless platform_family?('mac_os_x')
      gid validate_id(u['gid']) if u['gid']
      shell shell_is_valid?(u['shell']) ? u['shell'] : '/bin/sh'
      comment u['comment']
      password u['password'] if u['password']
      salt u['salt'] if u['salt']
      iterations u['iterations'] if u['iterations']
      manage_home manage_home
      home home_dir unless platform_family?('mac_os_x')
      action u['action'] if u['action']
    end

    if manage_home_files?(home_dir, u['username'])
      Chef::Log.debug("Managing home files for #{u['username']}")

      directory "#{home_dir}/.ssh" do
        recursive true
        owner u['uid'] ? validate_id(u['uid']) : u['username']
        group validate_id(u['gid']) if u['gid']
        mode '0700'
        only_if { !!(u['ssh_keys'] || u['ssh_private_key'] || u['ssh_public_key']) }
      end

      # loop over the keys and if we have a URL we should add each key
      # from the url response and append it to the list of keys
      ssh_keys = []
      if u['ssh_keys']
        Array(u['ssh_keys']).each do |key|
          if key.start_with?('https') || key.start_with?('INSECURE:http')
            ssh_keys += keys_from_url(key.delete_prefix('INSECURE:'))
          else
            ssh_keys << key
          end
        end
      end

      # use the keyfile defined in the databag or fallback to the standard file in the home dir
      key_file = u['authorized_keys_file'] || "#{home_dir}/.ssh/authorized_keys"

      template key_file do
        source 'authorized_keys.erb'
        cookbook new_resource.cookbook
        owner u['uid'] ? validate_id(u['uid']) : u['username']
        group validate_id(u['gid']) if u['gid']
        mode '0600'
        sensitive true
        # ssh_keys should be a combination of u['ssh_keys'] and any keys
        # returned from a specified URL
        variables ssh_keys: ssh_keys
        only_if { !!(u['ssh_keys']) }
      end

      if u['ssh_private_key']
        key_type = u['ssh_private_key'].include?('BEGIN RSA PRIVATE KEY') ? 'rsa' : 'dsa'
        template "#{home_dir}/.ssh/id_#{key_type}" do
          source 'private_key.erb'
          cookbook new_resource.cookbook
          owner u['uid'] ? validate_id(u['uid']) : u['username']
          group validate_id(u['gid']) if u['gid']
          mode '0400'
          variables private_key: u['ssh_private_key']
        end
      end

      if u['ssh_public_key']
        key_type = u['ssh_public_key'].include?('ssh-rsa') ? 'rsa' : 'dsa'
        template "#{home_dir}/.ssh/id_#{key_type}.pub" do
          source 'public_key.pub.erb'
          cookbook new_resource.cookbook
          owner u['uid'] ? validate_id(u['uid']) : u['username']
          group validate_id(u['gid']) if u['gid']
          mode '0400'
          variables public_key: u['ssh_public_key']
        end
      end
    else
      Chef::Log.debug("Not managing home files for #{u['username']}")
    end
  end
  # Populating users to appropriates groups
  users_groups.each do |g, u|
    group g do
      members u
      append true
      action :manage # Do nothing if group doesn't exist
    end unless g == new_resource.group_name # Dealing with managed group later
  end

  group new_resource.group_name do
    if platform_family?('mac_os_x')
      gid new_resource.group_id unless gid_used?(new_resource.group_id)
    else
      gid new_resource.group_id
    end
    members users_groups[new_resource.group_name]
  end
end

action :remove do
  search(new_resource.data_bag, "groups:#{new_resource.search_group} AND action:remove") do |rm_user|
    user rm_user['username'] ||= rm_user['id'] do
      action :remove
      manage_home rm_user['manage_home'] ||= false
      force rm_user['force'] ||= false
    end
  end
end

action_class do
  include ::Users::Helpers
  include ::Users::OsxHelper

  def manage_home_files?(home_dir, _user)
    # Don't manage home dir if it's NFS mount
    # and manage_nfs_home_dirs is disabled
    if home_dir == '/dev/null'
      false
    elsif fs_remote?(home_dir)
      new_resource.manage_nfs_home_dirs ? true : false
    else
      true
    end
  end
end
