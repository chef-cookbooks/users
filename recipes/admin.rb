#
# Cookbook Name:: users
# Recipe:: admins
#
# Copyright 2009-2011, Opscode, Inc.
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

# Searches data bag "users" for groups attribute "admin".
# Places returned users in Unix group "admin" with GID 2300.

begin
  admin = Etc.getgrnam('admin')
rescue ArgumentError
  admin = nil
end

gid = admin.nil? ? 110 : admin['gid']

users_manage "admin" do
  group_id gid
  action [ :remove, :create ]
end