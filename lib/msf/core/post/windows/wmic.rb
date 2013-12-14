# -*- coding: binary -*-

module Msf
class Post
module Windows

module WMIC

  include Msf::Post::Windows::ExtAPI

  def initialize(info = {})
    super

    register_options([
                         OptString.new('SMBUser', [ false, 'The username to authenticate as' ]),
                         OptString.new('SMBPass', [ false, 'The password for the specified username' ]),
                         OptString.new('SMBDomain',  [ false, 'The Windows domain to use for authentication' ]),
                         OptAddress.new("RHOST", [ true, "Target address range", "localhost" ]),
                     ], self.class)
  end

  def wmic_command(cmd, server=datastore['RHOST'])
    raise RuntimeError, "WMIC: Unable to load Extended API" unless load_extapi

    if datastore['SMBUser']
      if server.downcase == "localhost" || server.downcase.starts_with("127.")
        raise RuntimeError, "WMIC: User credentials cannot be used for local connections"
      end
    end

    wcmd = "wmic #{wmic_user_pass_string}/output:CLIPBOARD /INTERACTIVE:off /node:#{server} process call create \"#{cmd.gsub('"','\\"')}\""
    vprint_status("[#{server}] #{wcmd}")

    # We dont use cmd_exec as WMIC cannot be Channelized
    ps = session.sys.process.execute(wcmd, "", {'Hidden' => true, 'Channelized' => false})
    session.railgun.kernel32.WaitForSingleObject(ps.handle, 10000)
    ps.close

    result = session.extapi.clipboard.get_data.first

    if result[:type] == :text
      result_text = result[:data]
    else
      result_text = ""
    end

    vprint_status("[#{server}] WMIC Command Result:")
    vprint_line(result_text)
    parsed_result = parse_wmic_result(result_text)

    if parsed_result == nil
      vprint_error("[#{server}] WMIC Command Error")
    end

    session.extapi.clipboard.set_text("")

    return parsed_result
  end

  def parse_wmic_result(result_text)
    if result_text.blank?
      return nil
    else
      pid = nil
      return_value = nil

      if result_text =~ /ProcessId = (\d+);/
        pid = $1.to_i
      end

      if result_text =~ /ReturnValue = (\d+);/
        return_value = $1.to_i
      end

      return {:return_value => return_value, :pid => pid}
    end
  end

  def wmic_user_pass_string(domain=datastore['SMBDomain'], user=datastore['SMBUser'], pass=datastore['SMBPass'])
    userpass = ""

    unless user.nil?
      if domain.nil?
        userpass = "/user:\"#{user}\" /password:\"#{pass}\" "
      else
        userpass = "/user:\"#{domain}\\#{user}\" /password:\"#{pass}\" "
      end
    end

    return userpass
  end

end # WMIC
end # Windows
end # Post
end # Msf
