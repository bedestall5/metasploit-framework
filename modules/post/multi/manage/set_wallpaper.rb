##
# This module requires Metasploit: http://metasploit.com/download
# Current source: https://github.com/rapid7/metasploit-framework
##

require 'msf/core'

class Metasploit3 < Msf::Post

  include Msf::Post::File
  include Msf::Post::Windows::Registry

  def initialize(info={})
    super( update_info( info,
      'Name'          => 'Multi Manage Set Wallpaper',
      'Description'   => %q{
        This module will set the desktop wallpaper background on the specified session.
        The method of setting the wallpaper depends on the platform type.
      },
      'License'       => MSF_LICENSE,
      'Author'        => [ 'timwr'],
      'Platform'      => [ 'win', 'osx', 'linux', 'android' ],
      'SessionTypes'  => [ 'meterpreter' ]
    ))

    register_options(
      [
        OptPath.new('WALLPAPER_FILE', [true, 'The local wallpaper file to set on the remote session'])
      ], self.class)
  end

  def upload_wallpaper(tempdir)
    wallpaper_file = datastore["WALLPAPER_FILE"]
    remote_file = "#{tempdir}#{File.basename(wallpaper_file)}"
    print_status("#{peer} - Uploading to #{remote_file}")
    localfile = File.open(wallpaper_file, "rb") {|fd| fd.read(fd.stat.size) }
    write_file(remote_file, localfile)
    print_status("#{peer} - Uploaded to #{remote_file}")
    remote_file
  end

  #
  # The OSX version uses an apple script to do this
  #
  def osx_set_wallpaper
    remote_file = upload_wallpaper("/tmp/")
    script =  %Q|osascript -e 'tell application "Finder" to set desktop picture to POSIX file "#{remote_file}"' |
    begin
      cmd_exec(script)
    rescue EOFError
      return false
    end
    true
  end

  #
  # The Windows version uses the SystemParametersInfo
  #
  def win_set_wallpaper(id)
    remote_file = upload_wallpaper("%TEMP%\\")
    client.railgun.user32.SystemParametersInfoA(0x0014,nil,remote_file,0x2)
    true
  end

  #
  # The Android version uses the set_wallpaper command
  #
  def android_set_wallpaper(id)
    wallpaper_file = datastore["WALLPAPER_FILE"]
    local_file = File.open(wallpaper_file, "rb") {|fd| fd.read(fd.stat.size) }
    client.android.set_wallpaper(local_file)
    true
  end

  def set_wallpaper(id)
    case session.platform
    when /osx/
      osx_set_wallpaper(id)
    when /win/
      win_set_wallpaper(id)
    when /android/
      android_set_wallpaper(id)
    end
  end

  def run
    file = datastore['WALLPAPER_FILE']
    if set_wallpaper(file)
      print_good("#{peer} - The wallpaper has been set")
    else
      print_error("#{peer} - Unable to set the wallpaper")
    end
  end

end
