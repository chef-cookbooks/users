# Stage a web service that will serve files out of the /_keys directory to
# help validate that the user_manage resource can retrieve ssh keys via
# HTTP.
require 'webrick'
keyserver_ready = false
keyserver = WEBrick::HTTPServer.new(
  DocumentRoot: '/_keys',
  StartCallback: -> { keyserver_ready = true }
)

# Populate the /_keys directory with fake ssh keys for the tests.
directory '/_keys'
file '/_keys/test_user_keys_url.keys' do
  content <<~END_OF_SSH_KEYS
    ssh-rsa FAKE+RSA+KEY+DATA
    ecdsa-sha2-nistp256 FAKE+ECDSA+KEY+DATA
  END_OF_SSH_KEYS
end

# Start the web service and wait for it to begin accepting connections.
ruby_block 'start key server' do
  block do
    Thread.new { keyserver.start }
    [1..50].each do
      break if keyserver_ready
      sleep 0.1
    end
  end
end

user 'mwaddams' do
  manage_home true
  action :nothing
end

users_manage 'testgroup' do
  group_id 3000
  action [:remove, :create]
  data_bag 'test_home_dir'
  notifies :create, 'user[mwaddams]', :before
end

users_manage 'nfsgroup' do
  group_id 4000
  action [:remove, :create]
  data_bag 'test_home_dir'
  manage_nfs_home_dirs false
end

# Shutdown the web service.
ruby_block 'stop key server' do
  block { keyserver.shutdown }
end
