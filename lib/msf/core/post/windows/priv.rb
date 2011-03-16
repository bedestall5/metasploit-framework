
require 'msf/core/post/windows/accounts'

module Msf
class Post

module Priv

	include ::Msf::Post::Accounts
	# Returns true if user is admin and false if not.
	def is_admin?
		return session.railgun.shell32.IsUserAnAdmin()["return"]
	end

	# Returns true if running as Local System
	def is_system?
		local_sys = resolve_sid("S-1-5-18")
		if session.sys.config.getuid == "#{local_sys[:domain]}\\#{local_sys[:name]}"
			return true
		else
			return false
		end

	end
	#
	# Returns true if UAC is enabled
	#
	# Returns false if the session is running as system, if uac is disabled or
	# if running on a system that does not have UAC 
	#
	def is_uac_enabled?
		uac = false
		winversion = session.sys.config.sysinfo['OS']

		if winversion =~ /Windows (Vista|7|2008)/
			if session.sys.config.getuid != "NT AUTHORITY\\SYSTEM"
				begin
					key = session.sys.registry.open_key(HKEY_LOCAL_MACHINE, 'SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System',KEY_READ)

					if key.query_value('EnableLUA').data == 1
						uac = true
					end

					key.close
				rescue::Exception => e
					print_error("Error Checking UAC: #{e.class} #{e}")
				end
			end
		end
		return uac
	end

end
end
end
