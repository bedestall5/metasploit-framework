##
## $Id$
##

require 'workstation_driver'
require 'remote_workstation_driver'
#require 'dynagen_driver'
require 'virtualbox_driver'
#require 'amazon_driver'

module Lab

class Vm
	
	attr_accessor :vmid
	attr_accessor :driver
	attr_accessor :credentials
	attr_accessor :tools
	attr_accessor :type

	## Initialize takes a vm configuration hash of the form
	##  - vmid (unique identifier)
	##    driver (vm technology)
	##    user (if applicable)
	##    host (if applicable)
	##    location (file / uri)
	##    credentials (of the form [ {'user'=>"user",'pass'=>"pass", 'admin' => false}, ... ])
	def initialize(config = {})	

		## Mandatory
		@vmid = config['vmid'] 
		raise Exception, "Invalid VMID" unless @vmid 

		@driver = nil
		driver_type = config['driver']
		driver_type.downcase!


		## Optional
		@location = config['location'] ## only optional in the case of virtualbox (currently)
		@type = config['type'] || "unspecified"
		@tools = config['tools'] || false		## TODO
		@credentials = config['credentials'] || []
		@operating_system = nil				## TODO
		@ports = nil					## TODO
		@vulns = nil					## TODO

		## Only applicable to remote systems
		@user = config['user'] || nil
		@host = config['host'] || nil

		if driver_type == "workstation"
			@driver = Lab::Drivers::WorkstationDriver.new(@location, @credentials)
		elsif driver_type == "remote_workstation"
			@driver = Lab::Drivers::RemoteWorkstationDriver.new(@location, @user, @host, @credentials)	
		#elsif driver_type == "dynagen"
		#	@driver = Lab::Drivers::DynagenDriver.new	
		elsif driver_type == "virtualbox"
			@driver = Lab::Drivers::VirtualBoxDriver.new(@vmid, @location)
		#elsif driver_type == "amazon"
		#	@driver = Lab::Drivers::AmazonDriver.new	
		else
			raise Exception, "Unknown Driver Type"
		end
	end

	
	def running?
		@driver.running?
	end

	def location
		@driver.location
	end

	def start
		@driver.start
	end

	def stop
		@driver.stop
	end

	def pause
		@driver.pause
	end

	def suspend
		@driver.suspend
	end
	
	def reset
		@driver.reset
	end
	
	def resume
		@driver.resume
	end

	def create_snapshot(snapshot)
		@driver.create_snapshot(snapshot)
	end

	def revert_snapshot(snapshot)
		@driver.revert_snapshot(snapshot)
	end

	def delete_snapshot(snapshot)
		@driver.delete_snapshot(snapshot)
	end

	def revert_and_start(snapshot)
		self.revert_snapshot(snapshot)
		self.start
	end

	def copy_to(from_file,to_file)
		raise Exception, "not implemented"
	end
	
	def copy_from(from_file,to_file)
		raise Exception, "not implemented"
	end
	
	def run_command(command,arguments=nil)
		raise Exception, "not implemented"
	end

	def open_uri(uri)
		raise Exception, "not implemented"
	end

	def to_s
		return @vmid.to_s + ": " + @location.to_s
	end

	def to_yaml
		out =  " - vmid: #{@vmid}\n"
		out += "   driver: #{@driver.type}\n"
		out += "   location: #{@driver.location}\n"
		out += "   type: #{@type}\n"
		out += "   tools: #{@tools}\n"
		out += "   credentials:\n"
		@credentials.each do |credential|		
			out += "     - user: #{credential['user']}\n"
			out += "       pass: #{credential['pass']}\n"
			out += "       admin: #{credential['admin']}\n"
		end
		
		if @server_user or @server_host
			out += "   server_user: #{@server_user}\n"
			out += "   server_host: #{@server_host}\n"
		end

	 	return out
	end		
end

end
