require 'metasploit/framework/data_service/remote/http/remote_service_endpoint'
require 'metasploit/framework/data_service'
require 'metasploit/framework/data_service/remote/http/data_service_auto_loader'

#
# Parent data service for managing metasploit data in/on a separate process/machine over HTTP(s)
#
module Metasploit
module Framework
module DataService
class RemoteHTTPDataService
  include Metasploit::Framework::DataService
  include DataServiceAutoLoader

  ONLINE_TEST_URL = "/api/1/msf/online"
  EXEC_ASYNC = {:exec_async => true}
  GET_REQUEST = 'GET'
  POST_REQUEST = 'POST'

  #
  # @param endpoint - A RemoteServiceEndpoint. Cannot be nil
  #
  def initialize(endpoint)
    validate_endpoint(endpoint)
    @endpoint = endpoint
    build_client_pool(5)
  end

  #
  # POST data and don't wait for the endpoint to process the data before getting a response
  #
  def post_data_async(path, data_hash)
    post_data(path, data_hash.merge(EXEC_ASYNC))
  end

  #
  # POST data to the HTTP endpoint
  #
  # @param data_hash - A hash representation of the object to be posted. Cannot be nil or empty.
  # @param path - The URI path to post to
  #
  # @return A wrapped response (ResponseWrapper), see below.
  #
  def post_data(path, data_hash)
    begin
      raise 'Data to post to remote service cannot be null or empty' if (data_hash.nil? || data_hash.empty?)

      client =  @client_pool.pop()
      request_opts = build_request_opts(POST_REQUEST, data_hash, path)
      request = client.request_raw(request_opts)
      response = client._send_recv(request)

      if response.code == 200
        #puts "POST request: #{path} with body: #{json_body} sent successfully"
        return SuccessResponse.new(response)
      else
        puts "POST request: #{path} with body: #{json_body} failed with code: #{response.code} message: #{response.body}"
        return FailedResponse.new(response)
      end
    rescue Exception => e
      puts "Problem with POST request: #{e.message}"
      e.backtrace.each do |line|
        puts "#{line}\n"
      end
    ensure
      @client_pool << client
    end
  end

  #
  # GET data from the HTTP endpoint
  #
  # @param path - The URI path to post to
  # @param data_hash - A hash representation of the object to be posted. Can be nil or empty.
  #
  # @return A wrapped response (ResponseWrapper), see below.
  #
  def get_data(path, data_hash = nil)
    begin
      client =  @client_pool.pop()
      request_opts = build_request_opts(GET_REQUEST, data_hash, path)
      request = client.request_raw(request_opts)
      response = client._send_recv(request)

      if (response.code == 200)
        # puts 'request sent successfully'
        return SuccessResponse.new(response)
      else
        puts "GET request: #{path} failed with code: #{response.code} message: #{response.body}"
        return FailedResponse.new(response)
      end
    rescue Exception => e
        puts "Problem with GET request: #{e.message}"
    ensure
      @client_pool << client
    end
  end

  #
  # TODO: fix this
  #
  def active
    return true
  end

  # def do_nl_search(search)
  #   search_item = search.query.split(".")[0]
  #   case search_item
  #     when "host"
  #       do_host_search(search)
  #   end
  # end

  # def active
  #   begin
  #     request_opts = {'method' => 'GET', 'uri' => ONLINE_TEST_URL}
  #     request = @client.request_raw(request_opts)
  #     response = @client._send_recv(request)
  #     if response.code == 200
  #       try_sound_effect()
  #       return true
  #     else
  #       puts "request failed with code: #{response.code} message: #{response.message}"
  #       return false
  #     end
  #   rescue Exception => e
  #     puts "Unable to contact goliath service: #{e.message}"
  #     return false
  #   end
  # end

  def name
    "remote_data_service: (#{@endpoint})"
  end

  def set_header(key, value)
    if (@headers.nil?)
      @headers = Hash.new()
    end

    @headers[key] = value
  end

  #########
  protected
  #########

  #
  # Simple response wrapper
  #
  class ResponseWrapper
    attr_reader :response
    attr_reader :expected

    def initialize(response, expected)
      @response = response
      @expected = expected
    end
  end

  #
  # Failed response wrapper
  #
  class FailedResponse < ResponseWrapper
    def initialize(response)
      super(response, false)
    end
  end

  #
  # Success response wrapper
  #
  class SuccessResponse < ResponseWrapper
    def initialize(response)
      super(response, true)
    end
  end

  #######
  private
  #######

  def validate_endpoint(endpoint)
    raise 'Endpoint cannot be nil' if endpoint.nil?
    raise "Endpoint: #{endpoint.class} not of type RemoteServiceEndpoint" unless endpoint.is_a?(RemoteServiceEndpoint)
  end

  def append_workspace(data_hash)
    workspace = data_hash[:workspace]
    unless (workspace)
      workspace = data_hash.delete(:wspace)
    end

    if (workspace && (workspace.is_a?(OpenStruct) || workspace.is_a?(::Mdm::Workspace)))
      data_hash['workspace'] = workspace.name
    end

    if (workspace.nil?)
      data_hash['workspace'] = current_workspace_name
    end

    data_hash
  end

  def build_request_opts(request_type, data_hash, path)
    request_opts = {
        'method' => request_type,
        'ctype' => 'application/json',
        'uri' => path}

    if (!data_hash.nil? && !data_hash.empty?)
      json_body = append_workspace(data_hash).to_json
      request_opts['data'] = json_body
    end

    if (!@headers.nil? && !@headers.empty?)
      request_opts['headers'] = @headers
    end

    request_opts
  end

  def build_client_pool(size)
    @client_pool = Queue.new()
    (1..size).each {
      @client_pool << Rex::Proto::Http::Client.new(
          @endpoint.host,
          @endpoint.port,
          {},
          @endpoint.use_ssl,
          @endpoint.ssl_version)
    }
  end

  def try_sound_effect()
    sound_file = ::File.join(Msf::Config.data_directory, "sounds", "Goliath_Online_Sound_Effect.wav")
    Rex::Compat.play_sound(sound_file)
  end

end
end
end
end

