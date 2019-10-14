##
# This module requires Metasploit: https://metasploit.com/download
# Current source: https://github.com/rapid7/metasploit-framework
##

class MetasploitModule < Msf::Auxiliary

  include Msf::Auxiliary::Scanner
  include Msf::Exploit::Capture

  def initialize(info = {})
    super(update_info(info,
      'Name'           => 'URGENT/11 Scanner, Based on Detection Tool by Armis',
      'Description'    => %q{
        This module detects VxWorks and the IPnet IP stack, along with devices
        vulnerable to CVE-2019-12258.
      },
      'Author'         => [
        'Ben Seri',   # Upstream tool
        'Brent Cook', # Metasploit module
        'wvu'         # Metasploit module
      ],
      'References'     => [
        ['CVE', '2019-12258'],
        ['URL', 'https://armis.com/urgent11'],
        ['URL', 'https://github.com/ArmisSecurity/urgent11-detector']
      ],
      'DisclosureDate' => '2019-08-09', # NVD published date
      'License'        => MSF_LICENSE
    ))

    deregister_options('INTERFACE', 'PCAPFILE', 'FILTER')
  end

  def filter(ip)
    "src host #{ip} and dst host #{Rex::Socket.source_address(ip)}"
  end

  def run_host(ip)
    # XXX: Configuring Ethernet and IP headers sends a UDP packet!
    @config = PacketFu::Utils.whoami?(target: ip)

    open_pcap
    capture.setfilter(filter(ip))

    tcp_malformed_options_detection(ip)
    tcp_dos_detection(ip)
    icmp_code_detection(ip)
    icmp_timestamp_detection(ip)
  rescue RuntimeError => e
    fail_with(Failure::BadConfig, e.message)
  ensure
    close_pcap
  end

  def tcp_malformed_options_detection(ip)
  end

  def tcp_dos_detection(ip)
  end

  def icmp_code_detection(ip)
    p = PacketFu::ICMPPacket.new(config: @config)

    # IP
    p.ip_daddr = ip

    # ICMP
    p.icmp_type = 8    # Echo request
    p.icmp_code = 0x41 # Randomize?
    p.payload   = capture_icmp_echo_pack
    p.recalc

    vprint_status(p.inspect)
    p.to_w

    r = inject_reply(:icmp)

    return unless r && r.icmp_type == 0 # Echo reply

    require 'pry'; binding.pry
  end

  def icmp_timestamp_detection(ip)
    p = PacketFu::ICMPPacket.new(config: @config)

    # IP
    p.ip_daddr = ip

    # ICMP
    p.icmp_type = 13         # Timestamp request
    p.icmp_code = 0          # Timestamp
    p.payload   = "\x00" * 4 # Truncated
    p.recalc

    vprint_status(p.inspect)
    p.to_w

    r = inject_reply(:icmp)

    return unless r && r.icmp_type == 14 # Timestamp reply

    require 'pry'; binding.pry
  end

end
