#
# Web assessment for the metasploit framework
# Efrain Torres    - et[ ] metasploit.com  2010
#
# $Id$
# $Revision$
#

require 'rabal/tree'
require 'rexml/document'
require 'tempfile'
require 'rubygems'
require 'active_record'

module Msf

#
# Constants
#

WMAPVersion = "0.9"
WMAPAuthor = "ET  et [  ] metasploit.com"
WMAPBanner = "\n========[ WMAP v#{WMAPVersion} ]=========\n= #{WMAPAuthor} =\n=============================="
WMAP_PATH = '/'
WMAP_CHECK = true
WMAP_RUNEXPL = true
WMAP_EXITIFSESS = true
WMAP_SHOW = 2**0
WMAP_EXPL = 2**1

PROXY_CMDLINE = "../ratproxy/ratproxy"
PROXY_DEFAULTOPTS = " -a -v " + File.join( ENV.fetch('HOME'), '.msf3') + " -b sqlite3.db"

CRAWLER_CMDLINE = "ruby " + File.join(Msf::Config.install_root,"tools", "msfcrawler.rb")
CRAWLER_DEFAULTOPTS = ""

# Command line does not allow multiline strings so we pass headers header:valueSEPARATOR
STR_HEADER_SEPARATOR = '&'

# Exclude files can be modified by setting datastore['WMAP_EXCLUDE_FILE']
WMAP_EXCLUDE_FILE = '.*\.(gif|jpg|png*)$'

RUN_WMAP_SERVER = true
RUN_WMAP_DIR_FILE = true
RUN_WMAP_QUERY = true
RUN_WMAP_BODY = true
RUN_WMAP_HEADERS = true
RUN_WMAP_UNIQUE_QUERY = true
RUN_WMAP_GENERIC = true


class Plugin::Wmap < Msf::Plugin
	class WmapCommandDispatcher
		include Msf::Ui::Console::CommandDispatcher

		def name
			"Wmap"
		end

		#
		# The initial command set
		#
		def commands
			{
				"wmap_website"  => "List website structure",
				"wmap_targets"  => "Targets in the database",
				"wmap_sql" => "Query the database",
				"wmap_run"  => "Automatically test/exploit everything",
				"wmap_proxy" => "Run mitm proxy",
				"wmap_crawl" => "Crawl website",
				"wmap_attack" => "Crawl and Test",
			}
		end

		def cmd_wmap_attack(*args)
			aurl = args.shift

			puri = URI.parse(val)
			tssl = (puri.scheme == "https") ? true : false

			if (puri.host.nil? or puri.host.empty?)
				print_error( "Error: target http(s)://target/path")
			else

				crawldefaultopts = ""
				rundefaultopts = ""

				crawlopts = crawldefaultopts + " -t " + aurl + " " + args.join(" ")
				runopts = rundefaultopts + " -t " + aurl + " " + args.join(" ")

				#print_status("Crawling")
				#cmd_wmap_crawl(crawlopts)

				print_status("Reloading targets")
				cmd_wmap_targets("-r")

				print_status("Selecting target")

				tid = -1
				framework.db.each_target do |tgt|
					if tgt.host == puri.host and tgt.port.to_i == puri.port.to_i
						tid = tgt.id
						print_status("Target ID: #{tid}")
					end
				end

				seltgt = framework.db.get_target(tid)
				if seltgt == nil
					print_error("Target id not found.")
				else
					seltgt.selected = 1
					seltgt.save
					print_status("Testing")
					cmd_wmap_run("")
				end
			end
		end

		def cmd_wmap_website(*args)
			print_status("Website structure")
			if selected_host == nil
				print_error("Target not selected.")
			else
				print_status("#{selected_host}:#{selected_port} SSL:#{selected_ssl}")
				print_tree(load_tree)
			end
			print_status("Done.")
		end

		def cmd_wmap_targets(*args)
			# Default behavior to handle hosts names in the db as RHOSTS only
			# accepts IP addresses
			accept_hostnames = true
			resolv_hosts = false


			args.push("-h") if args.length == 0

			while (arg = args.shift)
				case arg
				when '-a'
					target_url = args.shift

					if target_url == nil
						print_error("URI required (http://<user:pass>@host</uri>)")
						return
					else
						puri = uri_parse(target_url)

						scheme, authority, path, query = puri[2], puri[4], puri[5], puri[7]

						if(not authority)
							print_error("URI required (http://<user:pass>@host</uri>)")
							return
						end

						uri_ssl= 0
						if scheme == 'https'
							uri_ssl = 1
						end

						uri_auth = authority.split(':')

						uri_host = uri_auth[0]

						uri_port = 80
						if uri_auth[1]
							uri_port = uri_auth[1]
						end

						uri_path = path
						if path == nil or path == ''
							uri_path = '/'
						end

						if Rex::Socket.dotted_ip?(uri_host)
							hip = uri_host
							framework.db.create_target(hip, uri_port, uri_ssl, 0)
							print_status("Added target #{hip} #{uri_port} #{uri_ssl}")

							framework.db.create_request(hip,uri_port,uri_ssl,'GET',uri_path,'',query,'','','','')
							print_status("Added request #{uri_path} #{query}")
						else
							if accept_hostnames
								framework.db.create_target(uri_host, uri_port, uri_ssl, 0)
								print_status("Added target #{uri_host} #{uri_port} #{uri_ssl}")

								framework.db.create_request(uri_host,uri_port,uri_ssl,'GET',uri_path,'',query,'','','','')
								print_status("Added request #{uri_host} #{query}")
							else
								print_error("RHOSTS only accepts IP addresses: #{req.host}")

								if resolv_hosts
									hip = Rex::Socket.resolv_to_dotted(req.host)

									framework.db.create_target(hip, uri_port, uri_ssl, 0)
									print_status("Added target #{hip} #{uri_port} #{uri_ssl}")

									framework.db.create_request(hip,uri_port,uri_ssl,'GET',uri_path, '',query,'','','','')
									print_status("Added request #{uri_path} #{query}")
								end
							end
						end
					end
				when '-p'
					print_status("   Id. Host\t\t\t\t\tPort\tSSL")

					framework.db.each_target do |tgt|
						if tgt.ssl == 1
							usessl = "[*]"
						else
							usessl = ""
						end

						maxcols = 35
						cols = maxcols - tgt.host.length

						thost = "#{tgt.host.to_s[0..maxcols]}"+(" "*cols)

						if tgt.selected == 1
							print_status("=> #{tgt.id}. #{thost}\t#{tgt.port}\t#{usessl}")
						else
							print_status("   #{tgt.id}. #{thost}\t#{tgt.port}\t#{usessl}")
						end
					end
					print_status("Done.")
				when '-r'
					framework.db.delete_all_targets
					framework.db.each_distinct_target do |req|
						if Rex::Socket.dotted_ip?(req.host)
							framework.db.create_target(req.host, req.port, req.ssl, 0)
							print_status("Added. #{req.host} #{req.port} #{req.ssl}")
						else
							if accept_hostnames
									framework.db.create_target(req.host, req.port, req.ssl, 0)
									print_status("Added host #{req.host}")
							else
								print_error("RHOSTS only accepts IP addresses: #{req.host}")

								if resolv_hosts
									hip = Rex::Socket.resolv_to_dotted(req.host)
									framework.db.create_target(hip, req.port, req.ssl, 0)
									print_status("Added host #{req.host} resolved as #{hip}.")
								end
							end
						end
					end
				when '-s'
					framework.db.each_target do |tgt|
						tgt.selected = 0
						tgt.save
					end
					seltgt = framework.db.get_target(args.shift)
					if seltgt == nil
						print_error("Target id not found.")
					else
						seltgt.selected = 1
						seltgt.save
					end
				when '-h'
					print_status("Usage: wmap_targets [options]")
					print_line("\t-h 		Display this help text")
					print_line("\t-c [url]  Crawl website (msfcrawler)")
					print_line("\t-p 		Print all available targets")
					print_line("\t-r 		Reload targets table")
					print_line("\t-s [id]	Select target for testing")
					print_line("\t-a [url]	Add new target")

					print_line("")
					return
				end
			end
		end

		def cmd_wmap_sql(*args)
			qsql = args.join(" ")

			args.push("-h") if args.length == 0

			while (arg = args.shift)
				case arg
				when '-h'
					print_status("Usage: wmap_sql [sql query]")
					print_line("\t-h 		Display this help text")

					print_line("")
					return
				end
			end

			print_line("SQL:  #{qsql}")

			begin
				res =framework.db.sql_query(qsql)
				res.each do |o|
					line = ''
					o.each do |k, v|
						if v
							line << v
						end
						line << '|'
					end
					print_line(line)
				end
			rescue ::Exception
				print_error("SQL Error #{$!}")
				return
			end
		end

		#
		# A copy of the shotgun approach to website exploitation
		#
		def cmd_wmap_run(*args)

			stamp = Time.now.to_f
			mode  = 0

			eprofile = []
			using_p = false

			args.push("-h") if args.length == 0

			while (arg = args.shift)
				case arg
				when '-t'
					mode |= WMAP_SHOW
				when '-e'
					mode |= WMAP_EXPL

					profile = args.shift

					if profile
						print_status("Using profile #{profile}.")

						begin
							File.open(profile).each do |str|
								if not str.include? '#'
									# Not a comment
									modname = str.strip
									if not modname.empty?
										eprofile << modname
									end
								end
								using_p = true
							end
						rescue
							print_error("Profile not found or invalid.")
							return
						end
					else
						print_status("Using ALL wmap enabled modules.")
					end


				when '-h'
					print_status("Usage: wmap_run [options]")
					print_line("\t-h		Display this help text")
					print_line("\t-t		Show all matching exploit modules")
					print_line("\t-e [profile]	Launch profile test modules against all matched targets.")
					print_line("\t		No profile runs all enabled modules.")

					print_line("")
					return
				end
			end

			if selected_host == nil
				print_error("Target not selected.")
				return
			end

			# WMAP_DIR, WMAP_FILE
			matches = {}

			# WMAP_SERVER
			matches1 = {}

			# WMAP_QUERY
			matches2 = {}

			# WMAP_BODY
			matches3 = {}

			# WMAP_HEADERS
			matches4 = {}

			# WMAP_UNIQUE_QUERY
			matches5 = {}

			# WMAP_GENERIC
			matches10 = {}

			# EXPLOIT OPTIONS
			opt_str = nil
			bg      = false
			jobify  = false

			[ [ framework.auxiliary, 'auxiliary' ], [framework.exploits, 'exploit' ] ].each do |mtype|

				# Scan all exploit modules for matching references
				mtype[0].each_module do |n,m|
					e = m.new

					# Only include wmap_enabled plugins
					if e.respond_to?("wmap_enabled")

						penabled = e.wmap_enabled

						if penabled
							if not using_p or eprofile.include? n.split('/').last
								#
								# First run the WMAP_SERVER plugins
								#
								case e.wmap_type
								when :WMAP_SERVER
									if RUN_WMAP_SERVER
									   matches1[[selected_host,selected_port,selected_ssl,mtype[1]+'/'+n]]=true
									end
								when :WMAP_QUERY
									if RUN_WMAP_QUERY
										matches2[[selected_host,selected_port,selected_ssl,mtype[1]+'/'+n]]=true
									end
								when :WMAP_BODY
									if RUN_WMAP_BODY
										matches3[[selected_host,selected_port,selected_ssl,mtype[1]+'/'+n]]=true
									end
								when :WMAP_HEADERS
									if RUN_WMAP_HEADERS
										matches4[[selected_host,selected_port,selected_ssl,mtype[1]+'/'+n]]=true
									end
								when :WMAP_UNIQUE_QUERY
									if RUN_WMAP_UNIQUE_QUERY
										matches5[[selected_host,selected_port,selected_ssl,mtype[1]+'/'+n]]=true
									end
								when :WMAP_GENERIC
									if RUN_WMAP_GENERIC
										matches10[[selected_host,selected_port,selected_ssl,mtype[1]+'/'+n]]=true
									end
								when :WMAP_DIR, :WMAP_FILE
									if RUN_WMAP_DIR_FILE
										matches[[selected_host,selected_port,selected_ssl,mtype[1]+'/'+n]]=true
									end
								else
									# Black Hole
								end
							end
						end
					end
				end
			end

			#
			# Handle modules that need to be run before all tests, once usually again the web server.
			# :WMAP_SERVER
			#
			idx = 0
			matches1.each_key do |xref|
				idx += 1

				begin
					mod = nil

					#Carefull with the references on this one
					if ((mod = framework.modules.create(xref[3])) == nil)
						print_status("Failed to initialize #{xref[3]}")
						next
					end

					if (mode & WMAP_SHOW != 0)
						print_status("Loaded #{xref[3]} ...")
					end

					#
					# The code is just a proof-of-concept and will be expanded in the future
					#
					if (mode & WMAP_EXPL != 0)

						#
						# For modules to have access to the global datastore
						# i.e. set -g DOMAIN test.com
						#
						self.framework.datastore.each do |gkey,gval|
							mod.datastore[gkey]=gval
						end

						#
						# For exploits
						#
						payload = mod.datastore['PAYLOAD']
						encoder = mod.datastore['ENCODER']
						target  = mod.datastore['TARGET']
						nop     = mod.datastore['NOP']

						#
						# Parameters passed in hash xref
						#
						mod.datastore['RHOST'] = xref[0]
						mod.datastore['RHOSTS'] = xref[0]
						mod.datastore['RPORT'] = xref[1].to_s
						mod.datastore['SSL'] = xref[2].to_s

						#
						# Run the plugins that only need to be
						# launched once.
						#

						wtype = mod.wmap_type

						if wtype == :WMAP_SERVER
							print_status("Launching #{xref[3]} #{wtype} against #{xref[0]}:#{xref[1]}")

							# To run check function for modules that are exploits
							if mod.respond_to?("check") and WMAP_CHECK
								begin
									session = mod.check_simple(
										'LocalInput' 	=> driver.input,
										'LocalOutput'	=> driver.output,
										'RunAsJob'   	=> false)

									if session
										stat = '[*]'

										if (session == Msf::Exploit::CheckCode::Vulnerable)
											stat = '[+]'
										end

										print_line(stat + ' ' + session[1])

										#
										# Exploit if WMAP_RUNEXPL
										#

										if (session == Msf::Exploit::CheckCode::Vulnerable) and WMAP_RUNEXPL
											print_status("Exploiting...")

											begin
												session = mod.exploit_simple(
													'Encoder'        => encoder,
													'Payload'        => payload,
													'Target'         => target,
													'Nop'            => nop,
													'OptionStr'      => opt_str,
													'LocalInput'     => driver.input,
													'LocalOutput'    => driver.output,
													'RunAsJob'       => jobify)
											rescue ::Interrupt
												raise $!
											rescue ::Exception => e
												print_error("Exploit failed: #{e.class} #{e}")
												if(e.class.to_s != 'Msf::OptionValidateError')
													print_error("Call stack:")
													e.backtrace.each do |line|
														break if line =~ /lib.msf.base.simple/
														print_error("  #{line}")
													end
												end
											end

											# If we were given a session, let's see what we can do with it
											if (session)

												# If we aren't told to run in the background and the session can be
												# interacted with, start interacting with it by issuing the session
												# interaction command.
												if (bg == false and session.interactive?)
													print_line

													driver.run_single("sessions -q -i #{session.sid}")
													# Otherwise, log that we created a session
												else
													print_status("Session #{session.sid} created in the background.")
												end
												# If we ran the exploit as a job, indicate such so the user doesn't
												# wonder what's up.

												if WMAP_EXITIFSESS
													return
												end
											elsif (jobify)
												print_status("Exploit running as background job.")
												# Worst case, the exploit ran but we got no session, bummer.
											else
												print_status("Exploit completed, but no session was created.")
											end

										end

									else
										print_error("Check failed: The state could not be determined.")
									end

								rescue ::Exception
									print_status(" >> Exception during check launch from #{xref[3]}: #{$!}")
								end

							else
								begin
									session = mod.run_simple(
										'LocalInput' 	=> driver.input,
										'LocalOutput'	=> driver.output,
										'RunAsJob'   	=> false)
								rescue ::Exception
									print_status(" >> Exception during launch from #{xref[3]}: #{$!}")
								end
							end
						end
					end

				rescue ::Exception
					print_status(" >> Exception from #{xref[3]}: #{$!}")
				end
			end

			#
			# Handle modules to be run at every path/file
			# WMAP_DIR, WMAP_FILE
			#
			idx = 0
			matches.each_key do |xref|
				idx += 1

				begin
					mod = nil

					#Carefull with the references on this one
					if ((mod = framework.modules.create(xref[3])) == nil)
						print_status("Failed to initialize #{xref[3]}")
						next
					end

					if (mode & WMAP_SHOW != 0)
						print_status("Loaded #{xref[3]} ...")
					end

					#
					# The code is just a proof-of-concept and will be expanded in the future
					#
					if (mode & WMAP_EXPL != 0)
												#
						# For modules to have access to the global datastore
						# i.e. set -g DOMAIN test.com
						#
						self.framework.datastore.each do |gkey,gval|
							mod.datastore[gkey]=gval
						end

						#
						# Parameters passed in hash xref
						#
						mod.datastore['RHOST'] = xref[0]
						mod.datastore['RHOSTS'] = xref[0]
						mod.datastore['RPORT'] = xref[1].to_s
						mod.datastore['SSL']   = xref[2].to_s

						#
						# Run the plugins that only need to be
						# launched once.
						#

						wtype = mod.wmap_type

						#
						#Here is where the fun begins
						#
						test_tree = load_tree()
						test_tree.each do |node|

							testpath = Pathname.new(node.current_path)
							strpath = testpath.cleanpath(false).to_s

							#
							# Fixing paths
							#

							if node.is_leaf? and not node.is_root?
								#
								# Later we can add here more checks to see if its a file
								#
							else
								if node.is_root?
									strpath = "/"
								else
									strpath = strpath.chomp + "/"
								end
							end

							strpath = strpath.gsub("//", "/")
							#print_status("Testing path: #{strpath}")

							#
							# Launch plugin depending module type.
							# Module type depends on main input type.
							# Code may be the same but it depend on final
							# versions of plugins
							#

							case wtype
							when :WMAP_FILE
								if node.is_leaf? and not node.is_root?
									#
									# Check if an exclusion regex has been defined
									#
									if self.framework.datastore['WMAP_EXCLUDE_FILE']
										excludefilestr = self.framework.datastore['WMAP_EXCLUDE_FILE']
									else
										excludefilestr = WMAP_EXCLUDE_FILE
									end

									if not strpath.match(excludefilestr)
										mod.datastore['PATH'] = strpath
										print_status("Launching #{xref[3]} #{wtype} #{strpath} against #{xref[0]}:#{xref[1]}...")

										# To run check function for modules that are exploits
										if mod.respond_to?("check") and WMAP_CHECK
											begin
												session = mod.check_simple(
													'LocalInput' 	=> driver.input,
													'LocalOutput'	=> driver.output,
													'RunAsJob'   	=> false)
											rescue ::Exception
												print_status(" >> Exception during check launch from #{xref[3]}: #{$!}")
											end
										else

											begin
												session = mod.run_simple(
													'LocalInput' 	=> driver.input,
													'LocalOutput'	=> driver.output,
													'RunAsJob'   	=> false)
											rescue ::Exception
												print_status(" >> Exception during launch from #{name}: #{$!}")
											end
										end
									end
								end
							when :WMAP_DIR
								if not node.is_leaf? or node.is_root?
									mod.datastore['PATH'] = strpath
									print_status("Launching #{xref[3]} #{wtype} #{strpath} against #{xref[0]}:#{xref[1]}...")

									# To run check function for modules that are exploits
									if mod.respond_to?("check") and WMAP_CHECK
										begin
											session = mod.check_simple(
												'LocalInput' 	=> driver.input,
												'LocalOutput'	=> driver.output,
												'RunAsJob'   	=> false)
										rescue ::Exception
											print_status(" >> Exception during check launch from #{xref[3]}: #{$!}")
										end
									else

										begin
											session = mod.run_simple(
												'LocalInput' 	=> driver.input,
												'LocalOutput'	=> driver.output,
												'RunAsJob'   	=> false)
										rescue ::Exception
											print_status(" >> Exception during launch from #{name}: #{$!}")
										end
									end
								end
							end
						end
					end
				rescue ::Exception
					print_status(" >> Exception from #{xref[3]}: #{$!}")
				end
			end

			#
			# Run modules for each request to play with URI with UNIQUE query parameters.
			# WMAP_UNIQUE_QUERY
			#
			idx = 0
			matches5.each_key do |xref|
				idx += 1

				begin
					mod = nil

					#Carefull with the references on this one
					if ((mod = framework.modules.create(xref[3])) == nil)
						print_status("Failed to initialize #{xref[3]}")
						next
					end

					if (mode & WMAP_SHOW != 0)
						print_status("Loaded #{xref[3]} ...")
					end

					#
					# The code is just a proof-of-concept and will be expanded in the future
					#
					if (mode & WMAP_EXPL != 0)
												#
						# For modules to have access to the global datastore
						# i.e. set -g DOMAIN test.com
						#
						self.framework.datastore.each do |gkey,gval|
							mod.datastore[gkey]=gval
						end

						#
						# Parameters passed in hash xref
						#
						mod.datastore['RHOST'] = xref[0]
						mod.datastore['RHOSTS'] = xref[0]
						mod.datastore['RPORT'] = xref[1].to_s
						mod.datastore['SSL'] = xref[2].to_s

						#
						# Run the plugins for each request that have a distinct
						# GET/POST  URI QUERY string.
						#

						wtype = mod.wmap_type

						utest_query = {}

						framework.db.each_request_target_with_query do |req|
							#
							# Only test unique query strings by comparing signature to previous tested signatures 'path,p1,p2,pn'
							#
							if (utest_query.has_key?(mod.signature(req.path,req.query)) == false)
								#
								# Weird bug req.method doesnt work
								# collides with some method named 'method'
								# column table renamed to 'meth'.
								#
								mod.datastore['METHOD'] = req.meth.upcase
								mod.datastore['PATH'] =  req.path
								mod.datastore['QUERY'] = req.query
								mod.datastore['HEADER_SEP'] = STR_HEADER_SEPARATOR
								mod.datastore['HEADERS'] = headers_to_s(req.headers,STR_HEADER_SEPARATOR)
								mod.datastore['COOKIE'] = header(req.headers,"Cookie")
								mod.datastore['DATA'] = req.body
								#
								# TODO: Add method, headers, etc.
								#

								if wtype == :WMAP_UNIQUE_QUERY
									print_status("Launching #{xref[3]} #{wtype} against #{xref[0]}:#{xref[1]}")

									# To run check function for modules that are exploits
									if mod.respond_to?("check") and WMAP_CHECK
										begin
											session = mod.check_simple(
												'LocalInput' 	=> driver.input,
												'LocalOutput'	=> driver.output,
												'RunAsJob'   	=> false)
										rescue ::Exception
											print_status(" >> Exception during check launch from #{xref[3]}: #{$!}")
										end
									else

										begin
											session = mod.run_simple(
												'LocalInput' 	=> driver.input,
												'LocalOutput'	=> driver.output,
												'RunAsJob'   	=> false)
										rescue ::Exception
											print_status(" >> Exception during launch from #{xref[3]}: #{$!}")
										end
									end
								end

								#
								# Unique query tested, actually the value does not matter
								#
								# print_status("#{mod.signature(req.path,req.query)}")
								utest_query[mod.signature(req.path,req.query)]=1
							end
						end
					end

				rescue ::Exception
					print_status(" >> Exception from #{xref[3]}: #{$!}")
				end
			end

			#
			# Run modules for each request to play with URI query parameters.
			# This approach will reduce the complexity of the Tree used before
			# and will make this shotgun implementation much simple.
			# WMAP_QUERY
			#
			idx = 0
			matches2.each_key do |xref|
				idx += 1

				begin
					mod = nil

					#Carefull with the references on this one
					if ((mod = framework.modules.create(xref[3])) == nil)
						print_status("Failed to initialize #{xref[3]}")
						next
					end

					if (mode & WMAP_SHOW != 0)
						print_status("Loaded #{xref[3]} ...")
					end

					#
					# The code is just a proof-of-concept and will be expanded in the future
					#
					if (mode & WMAP_EXPL != 0)

						#
						# For modules to have access to the global datastore
						# i.e. set -g DOMAIN test.com
						#
						self.framework.datastore.each do |gkey,gval|
							mod.datastore[gkey]=gval
						end

						#
						# Parameters passed in hash xref
						#
						mod.datastore['RHOST'] = xref[0]
						mod.datastore['RHOSTS'] = xref[0]
						mod.datastore['RPORT'] = xref[1].to_s
						mod.datastore['SSL'] = xref[2].to_s

						#
						# Run the plugins for each request that have a distinct
						# GET/POST  URI QUERY string.
						#

						wtype = mod.wmap_type


						framework.db.each_request_target_with_query do |req|
							#
							# Weird bug req.method doesnt work
							# collides with some method named 'method'
							# column table renamed to 'meth'.
							#
							mod.datastore['METHOD'] = req.meth.upcase
							mod.datastore['PATH'] =  req.path
							mod.datastore['QUERY'] = req.query
							mod.datastore['HEADER_SEP'] = STR_HEADER_SEPARATOR
							mod.datastore['HEADERS'] = headers_to_s(req.headers,STR_HEADER_SEPARATOR)
							mod.datastore['COOKIE'] = header(req.headers,"Cookie")
							mod.datastore['DATA'] = req.body

							#
							# TODO: Add method, headers, etc.
							#

							if wtype == :WMAP_QUERY
								print_status("Launching #{xref[3]} #{wtype} against #{xref[0]}:#{xref[1]}")

								# To run check function for modules that are exploits
								if mod.respond_to?("check") and WMAP_CHECK
									begin
										session = mod.check_simple(
											'LocalInput' 	=> driver.input,
											'LocalOutput'	=> driver.output,
											'RunAsJob'   	=> false)
									rescue ::Exception
										print_status(" >> Exception during check launch from #{xref[3]}: #{$!}")
									end
								else

									begin
										session = mod.run_simple(
											'LocalInput' 	=> driver.input,
											'LocalOutput'	=> driver.output,
											'RunAsJob'   	=> false)
									rescue ::Exception
										print_status(" >> Exception during launch from #{xref[3]}: #{$!}")
									end
								end
							end
						end
					end

				rescue ::Exception
					print_status(" >> Exception from #{xref[3]}: #{$!}")
				end
			end

			#
			# Run modules for each request to play with request bodies.
			# WMAP_BODY
			#
			idx = 0
			matches3.each_key do |xref|
				idx += 1

				begin
					mod = nil

					#Carefull with the references on this one
					if ((mod = framework.modules.create(xref[3])) == nil)
						print_status("Failed to initialize #{xref[3]}")
						next
					end

					if (mode & WMAP_SHOW != 0)
						print_status("Loaded #{xref[3]} ...")
					end

					#
					# The code is just a proof-of-concept and will be expanded in the future
					#
					if (mode & WMAP_EXPL != 0)

						#
						# For modules to have access to the global datastore
						# i.e. set -g DOMAIN test.com
						#
						self.framework.datastore.each do |gkey,gval|
							mod.datastore[gkey]=gval
						end

						#
						# Parameters passed in hash xref
						#
						mod.datastore['RHOST'] = xref[0]
						mod.datastore['RHOSTS'] = xref[0]
						mod.datastore['RPORT'] = xref[1].to_s
						mod.datastore['SSL'] = xref[2].to_s

						#
						# Run the plugins for each request for all headers
						# This can be improved alot . Later versions
						# Should only tests on unique requests.
						#

						wtype = mod.wmap_type


						framework.db.each_request_target_with_body do |req|
							#
							# Weird bug req.method doesnt work
							# collides with some method named 'method'
							# column table renamed to 'meth'.
							#
							mod.datastore['METHOD'] = req.meth.upcase
							mod.datastore['PATH'] =  req.path
							mod.datastore['QUERY'] = req.query
							mod.datastore['HEADER_SEP'] = STR_HEADER_SEPARATOR
							mod.datastore['HEADERS'] = headers_to_s(req.headers,STR_HEADER_SEPARATOR)
							mod.datastore['COOKIE'] = header(req.headers,"Cookie")
							mod.datastore['DATA'] = req.body
							#
							# TODO: Add method, headers, etc.
							#

							if wtype == :WMAP_BODY
								print_status("Launching #{xref[3]} #{wtype} against #{xref[0]}:#{xref[1]}")

								# To run check function for modules that are exploits
								if mod.respond_to?("check") and WMAP_CHECK
									begin
										session = mod.check_simple(
											'LocalInput' 	=> driver.input,
											'LocalOutput'	=> driver.output,
											'RunAsJob'   	=> false)
									rescue ::Exception
										print_status(" >> Exception during check launch from #{xref[3]}: #{$!}")
									end
								else

									begin
										session = mod.run_simple(
											'LocalInput' 	=> driver.input,
											'LocalOutput'	=> driver.output,
											'RunAsJob'   	=> false)
									rescue ::Exception
										print_status(" >> Exception during launch from #{xref[3]}: #{$!}")
									end
								end
							end
						end
					end

				rescue ::Exception
					print_status(" >> Exception from #{xref[3]}: #{$!}")
				end
			end

			#
			# Run modules for each request to play with request headers.
			# WMAP_HEADERS
			#
			idx = 0
			matches4.each_key do |xref|
				idx += 1

				begin
					mod = nil

					#Carefull with the references on this one
					if ((mod = framework.modules.create(xref[3])) == nil)
						print_status("Failed to initialize #{xref[3]}")
						next
					end

					if (mode & WMAP_SHOW != 0)
						print_status("Loaded #{xref[3]} ...")
					end

					#
					# The code is just a proof-of-concept and will be expanded in the future
					#
					if (mode & WMAP_EXPL != 0)
												#
						# For modules to have access to the global datastore
						# i.e. set -g DOMAIN test.com
						#
						self.framework.datastore.each do |gkey,gval|
							mod.datastore[gkey]=gval
						end

						#
						# Parameters passed in hash xref
						#
						mod.datastore['RHOST'] = xref[0]
						mod.datastore['RHOSTS'] = xref[0]
						mod.datastore['RPORT'] = xref[1].to_s
						mod.datastore['SSL'] = xref[2].to_s

						#
						# Run the plugins for each request for all headers
						# This can be improved alot . Later versions
						# Should only tests on unique requests.
						#

						wtype = mod.wmap_type


						framework.db.each_request_target_with_headers do |req|
							#
							# Weird bug req.method doesnt work
							# collides with some method named 'method'
							# column table renamed to 'meth'.
							#
							mod.datastore['METHOD'] = req.meth.upcase
							mod.datastore['PATH'] =  req.path
							mod.datastore['QUERY'] = req.query
							mod.datastore['HEADER_SEP'] = STR_HEADER_SEPARATOR
							mod.datastore['HEADERS'] = headers_to_s(req.headers,STR_HEADER_SEPARATOR)
							mod.datastore['COOKIE'] = header(req.headers,"Cookie")
							mod.datastore['DATA'] = req.body
							#
							# TODO: Add method, headers, etc.
							#

							if wtype == :WMAP_HEADERS
								print_status("Launching #{xref[3]} #{wtype} against #{xref[0]}:#{xref[1]}")

								# To run check function for modules that are exploits
								if mod.respond_to?("check") and WMAP_CHECK
									begin
										session = mod.check_simple(
											'LocalInput' 	=> driver.input,
											'LocalOutput'	=> driver.output,
											'RunAsJob'   	=> false)
									rescue ::Exception
										print_status(" >> Exception during check launch from #{xref[3]}: #{$!}")
									end
								else

									begin
										session = mod.run_simple(
											'LocalInput' 	=> driver.input,
											'LocalOutput'	=> driver.output,
											'RunAsJob'   	=> false)
									rescue ::Exception
										print_status(" >> Exception during launch from #{xref[3]}: #{$!}")
									end
								end
							end
						end
					end

				rescue ::Exception
					print_status(" >> Exception from #{xref[3]}: #{$!}")
				end
			end

			#
			# Handle modules that need to be after all tests, once.
			# Good place to have modules that analize the test results and/or
			# launch exploits.
			# :WMAP_GENERIC
			#
			idx = 0
			matches10.each_key do |xref|
				idx += 1

				begin
					mod = nil

					#Carefull with the references on this one
					if ((mod = framework.modules.create(xref[3])) == nil)
						print_status("Failed to initialize #{xref[3]}")
						next
					end

					if (mode & WMAP_SHOW != 0)
						print_status("Loaded #{xref[3]} ...")
					end

					#
					# The code is just a proof-of-concept and will be expanded in the future
					#
					if (mode & WMAP_EXPL != 0)

						#
						# For modules to have access to the global datastore
						# i.e. set -g DOMAIN test.com
						#
						self.framework.datastore.each do |gkey,gval|
							mod.datastore[gkey]=gval
						end

						#
						# Parameters passed in hash xref
						#
						mod.datastore['RHOST'] = xref[0]
						mod.datastore['RHOSTS'] = xref[0]
						mod.datastore['RPORT'] = xref[1].to_s
						mod.datastore['SSL'] = xref[2].to_s

						#
						# Run the plugins that only need to be
						# launched once.
						#

						wtype = mod.wmap_type

						if wtype == :WMAP_GENERIC
							print_status("Launching #{xref[3]} #{wtype} against #{xref[0]}:#{xref[1]}")

							# To run check function for modules that are exploits
							if mod.respond_to?("check") and WMAP_CHECK
								begin
									session = mod.check_simple(
										'LocalInput' 	=> driver.input,
										'LocalOutput'	=> driver.output,
										'RunAsJob'   	=> false)
								rescue ::Exception
									print_status(" >> Exception during check launch from #{xref[3]}: #{$!}")
								end
							else

								begin
									session = mod.run_simple(
										'LocalInput' 	=> driver.input,
										'LocalOutput'	=> driver.output,
										'RunAsJob'   	=> false)
								rescue ::Exception
									print_status(" >> Exception during launch from #{xref[3]}: #{$!}")
								end
							end
						end
					end

				rescue ::Exception
					print_status(" >> Exception from #{xref[3]}: #{$!}")
				end
			end

			if (mode & WMAP_SHOW != 0)
				print_status("Analysis completed in #{(Time.now.to_f - stamp)} seconds.")
				print_status("Done.")
			end

		# EOM
		end

		#
		# Run msf proxy
		#

		def cmd_wmap_proxy(*args)
			cmdline = PROXY_CMDLINE
			proxyopts = PROXY_DEFAULTOPTS + " " + args.join(" ")

			tpid = 0
			proxypid = Process.fork
			if proxypid.nil?
				exec cmdline + " " + proxyopts
			else
				tpid = proxypid
				Process.detach(proxypid)
			end
			print_status("Cmd: #{cmdline}")
			print_status("Options: #{proxyopts}")
			print_status("Executing proxy. pid: #{tpid}")
			print_status("Done.")
		end

		#
		# Run msf crawler
		#

		def cmd_wmap_crawl(*args)

			cmdline = CRAWLER_CMDLINE
			crawlopts = CRAWLER_DEFAULTOPTS + " " + args.join(" ")

			tpid = 0
			crawlpid = Process.fork
			if crawlpid.nil?
				exec cmdline + " " + crawlopts
			else
				tpid = crawlpid
				Process.detach(crawlpid)
			end
			print_status("Cmd: #{cmdline}")
			print_status("Options: #{crawlopts}")
			print_status("Crawler. pid: #{tpid}")
			print_status("Done.")
		end


		#
		# Load website structure into a tree
		#

		def load_tree
			wtree = Tree.new("ROOT_TREE")

			if selected_host == nil
				print_error("Target not selected")
			else
				framework.db.each_request_target do |req|
					tarray = req.path.to_s.split(WMAP_PATH)
					tarray.delete("")
					tpath = Pathname.new(WMAP_PATH)

					tarray.each do |df|
						wtree.add_at_path(tpath.to_s,df)
						tpath = tpath + Pathname.new(df.to_s)
					end
				end
			end
			return wtree
		end

		#
		# Print Tree structure. Ugly
		#

		def print_tree(tree)
			if tree.is_leaf? and tree.depth > 0
				print_line(("|\t"*(tree.depth-1))+"+------"+tree.name)
			else
				print_line(("|\t"*tree.depth)+tree.name)
			end
			tree.children.each_pair do |name,child|
					print_tree(child)
			end
		end

		#
		# Method to parse URIs Regex RFC3986
		#
		def uri_parse(uri)
			if uri == ''
				print_error("URI required")
				return
			end

			regexstr = '^(([^:/?#]+):)?(//([^/?#]*))?([^?#]*)(\?([^#]*))?(#(.*))?'

			regexurl = Regexp.new(regexstr, false)
			ret = regexurl.match(uri)

			return ret
		end

		#
		# Method to transfor headers to string
		#
		def headers_to_s(nheaders,hsep)
			hstr = ""
			nheaders.each_line do |lh|
				if hstr.empty?
					hstr = lh
				else
					hstr = lh + hsep + hstr
				end
			end
			return hstr
		end

		#
		# Method to grab a specific header
		#
		def header(nheaders,hname)
			nheaders.each_line do |lh|
				n,v = lh.split(": ")
				if n == hname
					return v
				end
			end
			return hstr
		end


		#
		# Selected target
		#
		def selected_host
			framework.db.selected_host
		end

		def selected_port
			framework.db.selected_port
		end

		def selected_ssl
			framework.db.selected_ssl
		end



	end

	def initialize(framework, opts)
		super
		add_console_dispatcher(WmapCommandDispatcher)
		print_status("#{WMAPBanner}")
	end

	def cleanup
		remove_console_dispatcher('Wmap')
	end

	def name
		"wmap"
	end

	def desc
		"Web assessment plugin"
	end

protected

end
end
