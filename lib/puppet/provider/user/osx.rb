## TODO LIST ##
#1. Tests
#2. Check individual getter/setter methods with Puppet manifests
#3. Make sure gid doesn't show up in groups - even with changes
#4. Fix create method to pass guid for 10.5/10.6 passwords

require 'puppet'
require 'facter/util/plist'
require 'pp'
require 'base64'

Puppet::Type.type(:user).provide :osx do
  desc "User management on OS X."

##                   ##
## Provider Settings ##
##                   ##

  # Provider command declarations
  commands :uuidgen  => '/usr/bin/uuidgen'
  commands :dsimport => '/usr/bin/dsimport'
  commands :dscl     => '/usr/bin/dscl'
  commands :plutil   => '/usr/bin/plutil'

  # Provider confines and defaults
  confine    :operatingsystem => :darwin
  defaultfor :operatingsystem => :darwin

  # Need this to create getter/setter methods automagically
  # This command creates methods that return @property_hash[:value]
  mk_resource_methods

  # JJM: OS X can manage passwords.
  #      This needs to be a special option to dscl though (-passwd)
  has_feature :manages_passwords

  # JJM: comment matches up with the /etc/passwd concept of an user
  #options :comment, :key => "realname"
  #options :password, :key => "passwd"
  #autogen_defaults :home => "/var/empty", :shell => "/usr/bin/false"

  #verify :gid, "GID must be an integer" do |value|
  #  value.is_a? Integer
  #end

  #verify :uid, "UID must be an integer" do |value|
  #  value.is_a? Integer
  #end

##                  ##
## Instance Methods ##
##                  ##

  def self.ds_to_ns_attribute_map
    # This method exists to map the dscl values to the correct Puppet
    # properties. This stays relatively consistent, but who knows what
    # Apple will do next year...
    {
      'RecordName'       => :name,
      'PrimaryGroupID'   => :gid,
      'NFSHomeDirectory' => :home,
      'UserShell'        => :shell,
      'UniqueID'         => :uid,
      'RealName'         => :comment,
      'Password'         => :password,
      'GeneratedUID'     => :guid,
      'IPAddress'        => :ip_address,
      'ENetAddress'      => :en_address,
      'GroupMembership'  => :members,
    }
  end

  def self.ns_to_ds_attribute_map
    @ns_to_ds_attribute_map ||= ds_to_ns_attribute_map.invert
  end

  def self.instances
    # This method assembles an array of provider instances containing
    # information about every instance of the user type on the system (i.e.
    # every user and its attributes).
    get_all_users.collect do |user|
      self.new(generate_attribute_hash(user))
    end
  end

  def self.get_all_users
    # Return an array of hashes containing information about every user on
    # the system.
    Plist.parse_xml(dscl '-plist', '.', 'readall', '/Users')
  end

  def self.generate_attribute_hash(input_hash)
    # This method accepts an individual user plist, passed as a hash, and
    # strips the dsAttrTypeStandard: prefix that dscl adds for each key.
    # An attribute hash is assembled and returned from the properties
    # supported by the user type.
    attribute_hash = {}
    input_hash.keys.each do |key|
      ds_attribute = key.sub("dsAttrTypeStandard:", "")
      next unless ds_to_ns_attribute_map.keys.include?(ds_attribute)
      ds_value = input_hash[key]
      case ds_to_ns_attribute_map[ds_attribute]
        when :gid, :uid
          # OS X stores objects like uid/gid as strings.
          # Try casting to an integer for these cases to be
          # consistent with the other providers and the group type
          # validation
          begin
            ds_value = Integer(ds_value[0])
          rescue ArgumentError
            ds_value = ds_value[0]
          end
        else ds_value = ds_value[0]
      end
      attribute_hash[ds_to_ns_attribute_map[ds_attribute]] = ds_value
    end
    attribute_hash[:ensure] = :present
    attribute_hash[:provider] = :osx
    attribute_hash
  end

##                   ##
## Ensurable Methods ##
##                   ##

  def exists?
    # Check for existance of a user. Use a dscl call to determine whether
    # the user exists. Rescue the dscl error if the user doesn't exist
    # and return false.
    begin
      return true if dscl '.', 'read', "/Users/#{@resource.name}"
    rescue
      return false
    end
  end

  def create
    # This method is called if ensure => present is passed and the exists?
    # method returns false. Dscl will directly set most values, but the
    # setter methods will be used for any exceptions.
    dscl '.', '-create',  "/Users/#{@resource.name}"
    Puppet::Type.type(@resource.class.name).validproperties.each do |attribute|
      next if attribute == :ensure
      value = @resource.should(attribute)

      # Value defaults
      if value.nil?
        value = '20' if attribute == :gid
        value = next_system_id if attribute == :uid
        value = @resource.name if attribute == :comment
        value = '/bin/bash' if attribute == :shell
        value = "/Users/#{@resource.name}" if attribute == :home
      end

      ## Set values ##
      # For the :password and :groups properties, call the setter methods
      # to enforce those values. For everything else, use dscl with the
      # ns_to_ds_attribute_map to set the appropriate values.
      if value != "" and not value.nil?
        case attribute
        when :password
          send('password=', value)
        when :groups
          send('groups=', value)
        else
          begin
            dscl '.', '-merge', "/Users/#{@resource.name}", self.class.ns_to_ds_attribute_map[attribute], value
          rescue Puppet::ExecutionFailure => detail
            fail("Could not create #{@resource.class.name} #{@resource.name}: #{detail}")
          end
        end
      end
    end
  end

  def delete
    # This method is called when ensure => absent has been set.
    # Deleting a user is handled by dscl
    dscl '.', '-delete', "/Users/#{@resource.name}"
  end

##                       ##
## Getter/Setter Methods ##
##                       ##

  def groups
    # Local groups report group membership via dscl, and so this method gets
    # an array of hashes that correspond to every local group's attributes,
    # iterates through them, and populates an array with the list of groups
    # for which the user is a member (based on username).
    #
    # Note that using this method misses nested group membership. It will only
    # report explicit group membership.
    groups_array = []
    users_guid = get_attribute_from_dscl('Users', 'GeneratedUID')[0]

    get_list_of_groups.each do |group|
      groups_array << group["dsAttrTypeStandard:RecordName"][0] if group["dsAttrTypeStandard:GroupMembership"] and group["dsAttrTypeStandard:GroupMembership"].include?(@resource.name)
      groups_array << group["dsAttrTypeStandard:RecordName"][0] if group["dsAttrTypeStandard:GroupMembers"] and group["dsAttrTypeStandard:GroupMembers"].include?(users_guid)
    end
    groups_array.uniq.sort.join(',')
  end

  def groups=(value)
    # In the setter method we're only going to take action on groups for which
    # the user is not currently a member.
    groups_to_add = value.split(',') - groups.split(',')
    groups_to_add.each do |group|
      begin
        dscl '.', '-merge', "/Groups/#{group}", 'GroupMembership', @resource.name
        dscl '.', '-merge', "/Groups/#{group}", 'GroupMembers', get_attribute_from_dscl('Users', 'GeneratedUID')["dsAttrTypeStandard:GeneratedUID"][0]
      rescue
        fail("OS X Provider: Unable to add #{@resource.name} to #{group}")
      end
    end
  end

  def password
    # Passwords are hard on OS X, yo. 10.6 used a SHA1 hash, 10.7 used a
    # salted-SHA512 hash, and 10.8 used a salted-PBKDF2 password. The
    # password getter method uses Puppet::Util::Package.versioncmp to
    # compare the version of OS X (it handles the condition that 10.10 is
    # a version greater than 10.2) and then calls the correct method to
    # retrieve the password hash
    if (Puppet::Util::Package.versioncmp(Facter.value(:macosx_productversion_major), '10.7') == -1)
      user_guid = get_attribute_from_dscl('Users', 'GeneratedUID')['dsAttrTypeStandard:GeneratedUID'][0]
      get_sha1(user_guid)
    else
      shadow_hash_data = get_attribute_from_dscl('Users', 'ShadowHashData')
      return '*' if shadow_hash_data.empty?
      embedded_binary_plist = get_embedded_binary_plist(shadow_hash_data)
      if embedded_binary_plist['SALTED-SHA512']
        get_salted_sha512(embedded_binary_plist)
      else
        get_salted_sha512_pbkdf2('entropy', embedded_binary_plist)
      end
    end
  end

  def password=(value)
    # If you thought GETTING a password was bad, try SETTING it. This method
    # makes me want to cry. A thousand tears...
    #
    # I've been unsuccessful in tracking down a way to set the password for
    # a user using dscl that DOESN'T require passing it as plaintext. We were
    # also unable to get dsimport to work like this. Due to these downfalls,
    # the sanest method requires opening the user's plist, dropping in the
    # password hash, and serializing it back to disk. The problems with THIS
    # method revolve around dscl. Any time you directly modify a user's plist,
    # you need to flush the cache that dscl maintains.
    if (Puppet::Util::Package.versioncmp(Facter.value(:macosx_productversion_major), '10.7') == -1)
      write_sha1_hash(value)
    else
      if Facter.value(:macosx_productversion_major) == '10.7'
        if value.length != 136
          fail("OS X 10.7 requires a Salted SHA512 hash password of 136 characters.  Please check your password and try again.")
        end
      else
        if value.length != 256
           fail("OS X versions > 10.7 require a Salted SHA512 PBKDF2 password hash of 256 characters. Please check your password and try again.")
        end
      end
      write_password_to_users_plist(value)
    end
  end

  def iterations
    if (Puppet::Util::Package.versioncmp(Facter.value(:macosx_productversion_major), '10.7') > 0)
      shadow_hash_data = get_attribute_from_dscl('Users', 'ShadowHashData')
      return nil if shadow_hash_data.empty?
      embedded_binary_plist = get_embedded_binary_plist(shadow_hash_data)
      if embedded_binary_plist['SALTED-SHA512-PBKDF2']
        get_salted_sha512_pbkdf2('iterations', embedded_binary_plist)
      end
    end
  end

  def iterations=(value)
    if (Puppet::Util::Package.versioncmp(Facter.value(:macosx_productversion_major), '10.7') > 0)
      users_plist = Plist::parse_xml(plutil '-convert', 'xml1', '-o', '/dev/stdout', "#{users_plist_dir}/#{@resource.name}.plist")
      shadow_hash_data = get_shadow_hash_data(users_plist)
      set_salted_pbkdf2(users_plist, shadow_hash_data, 'iterations', value)
    end
  end

  def salt
    if (Puppet::Util::Package.versioncmp(Facter.value(:macosx_productversion_major), '10.7') > 0)
      shadow_hash_data = get_attribute_from_dscl('Users', 'ShadowHashData')
      return nil if shadow_hash_data.empty?
      embedded_binary_plist = get_embedded_binary_plist(shadow_hash_data)
      if embedded_binary_plist['SALTED-SHA512-PBKDF2']
        get_salted_sha512_pbkdf2('salt', embedded_binary_plist)
      end
    end
  end

  def salt=(value)
    if (Puppet::Util::Package.versioncmp(Facter.value(:macosx_productversion_major), '10.7') > 0)
      users_plist = Plist::parse_xml(plutil '-convert', 'xml1', '-o', '/dev/stdout', "#{users_plist_dir}/#{@resource.name}.plist")
      shadow_hash_data = get_shadow_hash_data(users_plist)
      set_salted_pbkdf2(users_plist, shadow_hash_data, 'salt', value)
    end
  end


  ##                ##
  ## Helper Methods ##
  ##                ##

  def users_plist_dir
    '/var/db/dslocal/nodes/Default/users'
  end

  def password_hash_dir
    '/var/db/shadow/hash'
  end

  def get_list_of_groups
    # Use dscl to retrieve an array of hashes containing attributes about all
    # of the local groups on the machine.
    Plist.parse_xml(dscl '-plist', '.', 'readall', '/Groups')
  end

  def get_attribute_from_dscl(path, keyname)
    # Perform a dscl lookup at the path specified for the specific keyname
    # value. The value returned is the first item within the array returned
    # from dscl
    Plist.parse_xml(dscl '-plist', '.', 'read', "/#{path}/#{@resource.name}", keyname)
  end

  def get_embedded_binary_plist(shadow_hash_data)
    # The plist embedded in the ShadowHashData key is a binary plist. The
    # facter/util/plist library doesn't read binary plists, so we need to
    # extract the binary plist, convert it to XML, and return it.
    embedded_binary_plist = Array(shadow_hash_data['dsAttrTypeNative:ShadowHashData'][0].delete(' ')).pack('H*')
    convert_binary_to_xml(embedded_binary_plist)
  end

  def convert_xml_to_binary(plist_data)
    # This method will accept a hash that has been returned from Plist::parse_xml
    # and convert it to a binary plist (string value).
    Puppet.debug('Converting XML plist to binary')
    Puppet.debug('Executing: \'plutil -convert binary1 -o - -\'')
    IO.popen('plutil -convert binary1 -o - -', mode='r+') do |io|
      io.write Plist::Emit.dump(plist_data)
      io.close_write
      @converted_plist = io.read
    end
    @converted_plist
  end

  def convert_binary_to_xml(plist_data)
    # This method will accept a binary plist (as a string) and convert it to a
    # hash via Plist::parse_xml.
    Puppet.debug('Converting binary plist to XML')
    Puppet.debug('Executing: \'plutil -convert xml1 -o - -\'')
    IO.popen('plutil -convert xml1 -o - -', mode='r+') do |io|
      io.write plist_data
      io.close_write
      @converted_plist = io.read
    end
    Puppet.debug('Converting XML values to a hash.')
    Plist::parse_xml(@converted_plist)
  end

  def next_system_id(min_id=20)
    # Get the next available uid on the system by getting a list of user ids,
    # sorting them, grabbing the last one, and adding a 1. Scientific stuff here.
    dscl_output = dscl '.', '-list', '/Users', 'uid'
    # We're ok with throwing away negative uids here. Also, remove nil values.
    user_ids = dscl_output.split.compact.collect { |l| l.to_i if l.match(/^\d+$/) }
    ids = user_ids.compact!.sort! { |a,b| a.to_f <=> b.to_f }
    # We're just looking for an unused id in our sorted array.
    ids.each_index do |i|
      next_id = ids[i] + 1
      return next_id if ids[i+1] != next_id and next_id >= min_id
    end
  end

  def get_salted_sha512(embedded_binary_plist)
    # The salted-SHA512 password hash in 10.7 is stored in the 'SALTED-SHA512'
    # key as binary data. That data is extracted and converted to a hex string.
    embedded_binary_plist['SALTED-SHA512'].string.unpack("H*")[0]
  end

  def get_salted_sha512_pbkdf2(field, embedded_binary_plist)
    # This method reads the passed embedded_binary_plist hash and returns values
    # according to which field is passed.  Arguments passed are the hash
    # containing the value read from the 'ShadowHashData' key in the User's
    # plist, and the field to be read (one of 'entropy', 'salt', or 'iterations')
    case field
    when 'salt', 'entropy'
      embedded_binary_plist['SALTED-SHA512-PBKDF2'][field].string.unpack('H*').first
    when 'iterations'
      Integer(embedded_binary_plist['SALTED-SHA512-PBKDF2'][field])
    else
      fail('Puppet has tried to read an incorrect value from the ' +
           "SALTED-SHA512-PBKDF2 hash. Acceptable fields are 'salt', " +
           "'entropy', or 'iterations'.")
    end
  end

  def get_sha1(guid)
    # In versions 10.5 and 10.6 of OS X, the password hash is stored in a file
    # in the /var/db/shadow/hash directory that matches the GUID of the user.
    password_hash = nil
    password_hash_file = "#{password_hash_dir}/#{guid}"
    if File.exists?(password_hash_file) and File.file?(password_hash_file)
      fail("Could not read password hash file at #{password_hash_file}") if not File.readable?(password_hash_file)
      f = File.new(password_hash_file)
      password_hash = f.read
      f.close
    end
    password_hash
  end

  def write_password_to_users_plist(value)
  #  # This method is only called on version 10.7 or greater. On 10.7 machines,
  #  # passwords are set using a salted-SHA512 hash, and on 10.8 machines,
  #  # passwords are set using PBKDF2. It's possible to have users on 10.8
  #  # who have upgraded from 10.7 and thus have a salted-SHA512 password hash.
  #  # If we encounter this, do what 10.8 does - remove that key and give them
  #  # a 10.8-style PBKDF2 password.
    users_plist = Plist::parse_xml(plutil '-convert', 'xml1', '-o', '/dev/stdout', "#{users_plist_dir}/#{@resource.name}.plist")
    shadow_hash_data = get_shadow_hash_data(users_plist)
    if Facter.value(:macosx_productversion_major) == '10.7'
      set_salted_sha512(users_plist, shadow_hash_data, value)
    else
      shadow_hash_data.delete('SALTED-SHA512') if shadow_hash_data['SALTED-SHA512']
      set_salted_pbkdf2(users_plist, shadow_hash_data, 'entropy', value)
    end
  end

  def get_shadow_hash_data(users_plist)
    # This method will return the binary plist that's embedded in the
    # ShadowHashData key of a user's plist, or false if it doesn't exist.
    if users_plist['ShadowHashData']
      password_hash_plist  = users_plist['ShadowHashData'][0].string
      convert_binary_to_xml(password_hash_plist)
    else
      false
    end
  end

  def set_salted_sha512(users_plist, shadow_hash_data, value)
    # Puppet requires a salted-sha512 password hash for 10.7 users to be passed
    # in Hex, but the embedded plist stores that value as a Base64 encoded
    # string. This method converts the string and calls the
    # write_users_plist_to_disk method to serialize and write the plist to disk.
    unless shadow_hash_data
      shadow_hash_data = Hash.new
      shadow_hash_data['SALTED-SHA512'] = StringIO.new
    end
    shadow_hash_data['SALTED-SHA512'].string = Base64.decode64([[value].pack("H*")].pack("m").strip)
    binary_plist = convert_xml_to_binary(shadow_hash_data)
    users_plist['ShadowHashData'][0].string = binary_plist
    write_users_plist_to_disk(users_plist)
  end

  def set_salted_pbkdf2(users_plist, shadow_hash_data, field, value)
    # This method accepts a passed value and one of three fields: 'salt',
    # 'entropy', or 'iterations'.  These fields correspond with the fields
    # utilized in a PBKDF2 password hashing system
    # (see http://en.wikipedia.org/wiki/PBKDF2 ) where 'entropy' is the
    # password hash, 'salt' is the password hash salt value, and 'iterations'
    # is an integer recommended to be > 10,000. The remaining arguments are
    # the user's plist itself, and the shadow_hash_data hash containing the
    # existing PBKDF2 values.
    shadow_hash_data = Hash.new unless shadow_hash_data
    shadow_hash_data['SALTED-SHA512-PBKDF2'] = Hash.new unless shadow_hash_data['SALTED-SHA512-PBKDF2']
    case field
    when 'salt', 'entropy'
      shadow_hash_data['SALTED-SHA512-PBKDF2'][field] =  StringIO.new unless shadow_hash_data['SALTED-SHA512-PBKDF2'][field]
      shadow_hash_data['SALTED-SHA512-PBKDF2'][field].string = Base64.decode64([[value].pack("H*")].pack("m").strip)
    when 'iterations'
      shadow_hash_data['SALTED-SHA512-PBKDF2'][field] = Integer(value)
    else
      fail("Puppet has tried to set an incorrect field for the 'SALTED-SHA512-PBKDF2' hash. Acceptable fields are 'salt', 'entropy', or 'iterations'.")
    end

    # on 10.8, this field *must* contain 8 stars, or authentication will
    # fail.
    users_plist['passwd'] = ('*' * 8)

    # Convert shadow_hash_data to a binary plist, write that value to the
    # users_plist hash, and write the users_plist back to disk.
    binary_plist = convert_xml_to_binary(shadow_hash_data)
    users_plist['ShadowHashData'][0].string = binary_plist
    write_users_plist_to_disk(users_plist)
  end

  def write_users_plist_to_disk(users_plist)
    # This method will accept a plist in XML format, save it to disk, convert
    # the plist to a binary format, and flush the dscl cache.
    Plist::Emit.save_plist(users_plist, "#{users_plist_dir}/#{@resource.name}.plist")
    plutil'-convert', 'binary1', "#{users_plist_dir}/#{@resource.name}.plist"
    # Restart directoryservices or opendirectoryd
    # OR dscacheutil -cachedump
    # OR sleep 5
  end

  def write_sha1_hash(value)
    users_guid = get_attribute_from_dscl('Users', 'GeneratedUID')[0]
    password_hash_file = "#{password_hash_dir}/#{users_guid}"
    begin
      File.open(password_hash_file, 'w') { |f| f.write(value)}
    rescue Errno::EACCES => detail
      fail("Could not write to password hash file: #{detail}")
    end

    # NBK: For shadow hashes, the user AuthenticationAuthority must contain a value of
    # ";ShadowHash;". The LKDC in 10.5 makes this more interesting though as it
    # will dynamically generate ;Kerberosv5;;username@LKDC:SHA1 attributes if
    # missing. Thus we make sure we only set ;ShadowHash; if it is missing, and
    # we can do this with the merge command. This allows people to continue to
    # use other custom AuthenticationAuthority attributes without stomping on them.
    #
    # There is a potential problem here in that we're only doing this when setting
    # the password, and the attribute could get modified at other times while the
    # hash doesn't change and so this doesn't get called at all... but
    # without switching all the other attributes to merge instead of create I can't
    # see a simple enough solution for this that doesn't modify the user record
    # every single time. This should be a rather rare edge case. (famous last words)

    begin
      dscl '.', '-merge',  "/Users/#{@resource.name}", 'AuthenticationAuthority', ';ShadowHash;'
    rescue Puppet::ExecutionFailure
      fail('Could not set AuthenticationAuthority to ;ShadowHash;')
    end
  end
end
