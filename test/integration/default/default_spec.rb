os_family = os.family

describe user('test_user') do
  it { should exist }
  its('uid') { should eq 9001 } unless os_family == 'darwin'
  case os_family
  when 'suse'
    its('groups') { should eq %w( users testgroup nfsgroup ) }
  when 'darwin'
    its('groups') { should include 'testgroup' }
    its('groups') { should include 'nfsgroup' }
  else
    its('groups') { should eq %w( test_user testgroup nfsgroup ) }
  end
  its('shell') { should eq '/bin/bash' }
end

describe group('testgroup') do
  it { should exist }
  its('gid') { should eq 3000 }
end

describe group('nfsgroup') do
  it { should exist }
  its('gid') { should eq 4000 }
end

describe user('test_user_keys_from_url') do
  it { should exist }
  its('uid') { should eq 9002 } unless os_family == 'darwin'
  case os_family
  when 'suse'
    its('groups') { should eq %w( users testgroup nfsgroup ) }
  when 'darwin'
    its('groups') { should include 'testgroup' }
    its('groups') { should include 'nfsgroup' }
  else
    its('groups') { should eq %w( test_user_keys_from_url testgroup nfsgroup ) }
  end
  its('shell') { should eq '/bin/bash' }
end

ssh_keys = [
  'ssh-rsa FAKE+RSA+KEY+DATA',
  'ecdsa-sha2-nistp256 FAKE+ECDSA+KEY+DATA',
]

describe file('/home/test_user_keys_from_url/.ssh/authorized_keys') do
  ssh_keys.each do |key|
    its('content') { should include(key) }
  end
end unless os_family == 'darwin' # InSpec runs as non-root and can't see these files
