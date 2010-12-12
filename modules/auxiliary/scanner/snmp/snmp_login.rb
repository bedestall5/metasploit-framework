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

	include Msf::Auxiliary::Report
	include Msf::Auxiliary::Scanner
	include Msf::Auxiliary::AuthBrute
	
	def initialize
		super(
			'Name'        => 'SNMP Community Scanner',
			'Version'     => '$Revision$',
			'Description' => 'Scan for SNMP devices using common community names',
			'Author'      => 'hdm',
			'License'     => MSF_LICENSE
		)

		register_options(
		[
			Opt::RPORT(161),
			Opt::CHOST,
			OptInt.new('BATCHSIZE', [true, 'The number of hosts to probe in each set', 256]),
			OptString.new('PASSWORD', [ false, 'The password to test' ]),
			OptPath.new('PASS_FILE',  [ false, "File containing communities, one per line",
				File.join(Msf::Config.install_root, "data", "wordlists", "snmp_default_pass.txt")
			])
		], self.class)
	end


	# Define our batch size
	def run_batch_size
		datastore['BATCHSIZE'].to_i
	end

	# Operate on an entire batch of hosts at once
	def run_batch(batch)

		@found = {}

		begin
			udp_sock = nil
			idx = 0

			# Create an unbound UDP socket if no CHOST is specified, otherwise
			# create a UDP socket bound to CHOST (in order to avail of pivoting)
			udp_sock = Rex::Socket::Udp.create( { 'LocalHost' => datastore['CHOST'] || nil, 'Context' => {'Msf' => framework, 'MsfExploit' => self} })
			add_socket(udp_sock)

			each_user_pass do |user, pass|
				comm = pass

				data1 = create_probe_snmp1(comm)
				data2 = create_probe_snmp2(comm)

				batch.each do |ip|

					begin
						udp_sock.sendto(data1, ip, datastore['RPORT'].to_i, 0)
						udp_sock.sendto(data2, ip, datastore['RPORT'].to_i, 0)
					rescue ::Interrupt
						raise $!
					rescue ::Rex::HostUnreachable, ::Rex::ConnectionTimeout, ::Rex::ConnectionRefused
						nil
					end

					if (idx % 10 == 0)
						while (r = udp_sock.recvfrom(65535, 0.01) and r[1])
							parse_reply(r)
						end
					end

				end
			end

			while (r = udp_sock.recvfrom(65535, 3) and r[1])
				parse_reply(r)
			end

		rescue ::Interrupt
			raise $!
		rescue ::Exception => e
			print_error("Unknown error: #{e.class} #{e}")
		end
	end


	#
	# The response parsers
	#
	def parse_reply(pkt)

		return if not pkt[1]

		if(pkt[1] =~ /^::ffff:/)
			pkt[1] = pkt[1].sub(/^::ffff:/, '')
		end

		asn = ASNData.new(pkt[0])
		inf = asn.access("L0.L0.L0.L0.V1.value")
		if (inf)
			inf.gsub!(/\r|\n/, ' ')
			inf.gsub!(/\s+/, ' ')
		end

		com = asn.access("L0.V1.value")
		if(com)
			@found[pkt[1]]||={}
			if(not @found[pkt[1]][com])
				print_good("SNMP: #{pkt[1]} community string: '#{com}' info: '#{inf}'")
				@found[pkt[1]][com] = inf
			end
			
			return if inf.to_s.length == 0

			report_service(
				:host   => pkt[1],
				:port   => pkt[2],
				:proto  => 'udp',
				:name  => 'snmp',
				:info   => inf,
				:state => "open"
			)

			report_auth_info(
				:host   => pkt[1],
				:port   => pkt[2],
				:proto  => 'udp',
				:sname  => 'snmp',
				:user   => '',
				:pass   => com,
				:duplicate_ok => true,
				:active => true
			)

		end
	end


	def create_probe_snmp1(name)
		xid = rand(0x100000000)
		pdu =
			"\x02\x01\x00" +
			"\x04" + [name.length].pack('c') + name +
			"\xa0\x1c" +
			"\x02\x04" + [xid].pack('N') +
			"\x02\x01\x00" +
			"\x02\x01\x00" +
			"\x30\x0e\x30\x0c\x06\x08\x2b\x06\x01\x02\x01" +
			"\x01\x01\x00\x05\x00"
		head = "\x30" + [pdu.length].pack('C')
		data = head + pdu
		data
	end

	def create_probe_snmp2(name)
		xid = rand(0x100000000)
		pdu =
			"\x02\x01\x01" +
			"\x04" + [name.length].pack('c') + name +
			"\xa1\x19" +
			"\x02\x04" + [xid].pack('N') +
			"\x02\x01\x00" +
			"\x02\x01\x00" +
			"\x30\x0b\x30\x09\x06\x05\x2b\x06\x01\x02\x01" +
			"\x05\x00"
		head = "\x30" + [pdu.length].pack('C')
		data = head + pdu
		data
	end


	#
	# Parse a asn1 buffer into a hash tree
	#

	class ASNData < ::Hash

		def initialize(data)
			_parse_asn1(data, self)
		end

		def _parse_asn1(data, tree)
			x = 0
			while (data.length > 0)
				t,l = data[0,2].unpack('CC')
				i = 2

				if (l > 0x7f)
					lb = l - 0x80
					l = (("\x00" * (4-lb)) + data[i, lb]).unpack('N')[0]
					i += lb
				end

				buff = data[i, l]

				tree[:v] ||= []
				tree[:l] ||= []
				case t
					when 0x00...0x29
						tree[:v] << [t, buff]
					else
						tree[:l][x] ||= ASNData.new(buff)
						x += 1
				end
				data = data[i + l, data.length - l]
			end
		end

		def access(desc)
			path = desc.split('.')
			node = self
			path.each_index do |i|
				case path[i]
					when /^V(\d+)$/
						if (node[:v] and node[:v][$1.to_i])
							node = node[:v][$1.to_i]
							next
						else
							return nil
						end
					when /^L(\d+)$/
						if (node[:l] and node[:l][$1.to_i])
							node = node[:l][$1.to_i]
							next
						else
							return nil
						end
					when 'type'
						return (node and node[0]) ? node[0] : nil
					when 'value'
						return (node and node[1]) ? node[1] : nil
					else
						return nil
				end
			end
			return node
		end
	end



end

