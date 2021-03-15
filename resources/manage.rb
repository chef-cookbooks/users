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
property :group_name, String, description: 'name of the group to create, defaults to resource name', name_property: true
property :group_id, Integer, description: 'numeric id of the group to create, default is to allow the OS to pick next.'
property :users, Array, description: 'Array of Hashses that contains all the users that you want to create with the users cookbook.'
property :cookbook, String, description: 'name of the cookbook that the authorized_keys template should be found in.', default: 'users'
property :manage_nfs_home_dirs, [true, false], description: 'specifies if home_dirs should be managed when they are located on a NFS share.', default: true

# Deprecated properties
property :data_bag, String, deprecated: 'The data_bag property has been deprecated, please see upgrading.md for more information. The property will be removed in the next major release.'

action :create do
  users_groups = {}
  users_groups[new_resource.group_name] = []

  # Loop through all the users in the users_hash
  # Break the loop if users is no in the specified group_name
  new_resource.users.each do |user|
    next unless user[:groups].include?(new_resource.group_name)
    next if user[:action] == 'remove'

    username = user[:username] || user[:id]
    user[:groups].each do |group|
      users_groups[group] = [] unless users_groups.key?(group)
      users_groups[group] << username
    end

    # Set home to location in data bag,
    # or a reasonable default ($home_basedir/$user).
    home_dir = user[:home] || "#{home_basedir}/#{username}"

    # check whether home dir is null
    manage_home = !(home_dir == '/dev/null')

    # Create the group from the group property if it does not yet exist.
    # The management of the members will be done in a seperate resource.
    group new_resource.group_name do
      if platform_family?('mac_os_x')
        gid new_resource.group_id unless gid_used?(new_resource.group_id)
        not_if "dscl . list /Groups/#{new_resource.group_name}"
      else
        gid new_resource.group_id
        not_if "getent group #{new_resource.group_name}"
      end
    end

    # Check if we need to create a user group for the user
    # True by default
    username_group = user[:no_user_group] ? false : true

    # The user block will fail if the group does not yet exist.
    # See the -g option limitations in man 8 useradd for an explanation.
    # This should correct that without breaking functionality.
    group username do
      if platform_family?('mac_os_x')
        gid user[:gid].to_i unless gid_used?(user[:gid].to_i) || new_resource.group_name == username
      else
        gid user[:gid].to_i
      end
      only_if { user[:gid] && user[:gid].is_a?(Numeric) && username_group && !platform_family?('windows') }
    end

    # Create user object.
    # Do NOT try to manage null home directories.
    user username do
      uid user[:uid].to_i unless platform_family?('mac_os_x') || !user[:uid]
      gid user[:gid].to_i if user[:gid] && !platform_family?('windows')
      shell shell_is_valid?(user[:shell]) ? user[:shell] : '/bin/sh'
      comment user[:comment]
      password user[:password] if user[:password]
      salt user[:salt] if user[:salt]
      iterations user[:iterations] if user[:iterations]
      manage_home manage_home
      home home_dir unless platform_family?('mac_os_x')
      action :create
    end

    if manage_home_files?(home_dir, username)
      Chef::Log.debug("Managing home files for #{username}")

      directory "#{home_dir}/.ssh" do
        recursive true
        owner user[:uid].to_i || username
        group user[:gid].to_i if user[:gid]
        mode '0700'
        not_if { user[:ssh_keys].nil? && user[:ssh_private_key].nil? && user[:ssh_public_key].nil? }
      end

      # loop over the keys and if we have a URL we should add each key
      # from the url response and append it to the list of keys
      ssh_keys = []
      Array(user[:ssh_keys]).each do |key|
        if key.start_with?('https')
          ssh_keys += keys_from_url(key)
        else
          ssh_keys << key
        end
      end

      # use the keyfile defined in the databag or fallback to the standard file in the home dir
      key_file = user[:authorized_keys_file] || "#{home_dir}/.ssh/authorized_keys"

      template key_file do
        source 'authorized_keys.erb'
        cookbook new_resource.cookbook
        owner user[:uid].to_i || username
        group user[:gid].to_i if user[:gid]
        mode '0600'
        sensitive true
        # ssh_keys should be a combination of user['ssh_keys'] and any keys
        # returned from a specified URL
        variables ssh_keys: ssh_keys
        not_if { user[:ssh_keys].nil? }
      end

      if user[:ssh_public_key]
        pubkey_type = pubkey_type(user[:ssh_public_key])
        template "#{home_dir}/.ssh/id_#{pubkey_type}.pub" do
          source 'public_key.pub.erb'
          cookbook new_resource.cookbook
          owner user[:uid] ? user[:uid].to_i : username
          group user[:gid].to_i if user[:gid]
          mode '0400'
          variables public_key: user[:ssh_public_key]
        end
      end

      if user[:ssh_private_key]
        key_type = pubkey_type || 'rsa'
        template "#{home_dir}/.ssh/id_#{key_type}" do
          source 'private_key.erb'
          cookbook new_resource.cookbook
          owner user[:uid].to_i || username
          group user[:gid].to_i if user[:gid]
          mode '0400'
          variables private_key: user[:ssh_private_key]
        end
      end
    else
      Chef::Log.debug("Not managing home files for #{username}")
    end
  end
  # Populating users to appropriates groups
  users_groups.each do |group, user|
    group group do
      members user
      append true
      action :manage # Do nothing if group doesn't exist
    end
  end
end

action :remove do
  new_resource.users.each do |user|
    next unless (user[:groups].include? new_resource.group_name) && (user[:action] == 'remove' unless user[:action].nil?)

    user user[:username] || user[:id] do
      action :remove
      manage_home user[:manage_home] || false
      force user[:force] || false
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
