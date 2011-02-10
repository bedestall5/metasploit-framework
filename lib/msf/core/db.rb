require 'rex/parser/nmap_xml'
require 'rex/parser/nexpose_xml'
require 'rex/parser/retina_xml'
require 'rex/parser/netsparker_xml'
require 'rex/parser/nessus_xml'
require 'rex/parser/ip360_xml'
require 'rex/parser/ip360_aspl_xml'
require 'rex/socket'
require 'zip'
require 'packetfu'
require 'uri'
require 'tmpdir'
require 'fileutils'

module Msf

###
#
# The states that a host can be in.
#
###
module HostState
	#
	# The host is alive.
	#
	Alive   = "alive"
	#
	# The host is dead.
	#
	Dead    = "down"
	#
	# The host state is unknown.
	#
	Unknown = "unknown"
end

###
#
# The states that a service can be in.
#
###
module ServiceState
	Open      = "open"
	Closed    = "closed"
	Filtered  = "filtered"
	Unknown   = "unknown"
end

###
#
# Events that can occur in the host/service database.
#
###
module DatabaseEvent

	#
	# Called when an existing host's state changes
	#
	def on_db_host_state(host, ostate)
	end

	#
	# Called when an existing service's state changes
	#
	def on_db_service_state(host, port, ostate)
	end

	#
	# Called when a new host is added to the database.  The host parameter is
	# of type Host.
	#
	def on_db_host(host)
	end

	#
	# Called when a new client is added to the database.  The client
	# parameter is of type Client.
	#
	def on_db_client(client)
	end

	#
	# Called when a new service is added to the database.  The service
	# parameter is of type Service.
	#
	def on_db_service(service)
	end

	#
	# Called when an applicable vulnerability is found for a service.  The vuln
	# parameter is of type Vuln.
	#
	def on_db_vuln(vuln)
	end

	#
	# Called when a new reference is created.
	#
	def on_db_ref(ref)
	end

end

class DBImportError < RuntimeError
end

###
#
# The DB module ActiveRecord definitions for the DBManager
#
###
class DBManager

	def rfc3330_reserved(ip)
		case ip.class.to_s
		when "PacketFu::Octets"
			ip_x = ip.to_x
			ip_i = ip.to_i
		when "String"
			if ipv4_validator(ip)
				ip_x = ip
				ip_i = Rex::Socket.addr_atoi(ip)
			else
				raise ArgumentError, "Invalid IP address: #{ip.inspect}"
			end
		when "Fixnum"
			if (0..2**32-1).include? ip
				ip_x = Rex::Socket.addr_itoa(ip)
				ip_i = ip
			else
				raise ArgumentError, "Invalid IP address: #{ip.inspect}"
			end
		else
			raise ArgumentError, "Invalid IP address: #{ip.inspect}"
		end
		return true if Rex::Socket::RangeWalker.new("0.0.0.0-0.255.255.255").include? ip_x
		return true if Rex::Socket::RangeWalker.new("127.0.0.0-127.255.255.255").include? ip_x
		return true if Rex::Socket::RangeWalker.new("169.254.0.0-169.254.255.255").include? ip_x
		return true if Rex::Socket::RangeWalker.new("224.0.0.0-239.255.255.255").include? ip_x
		return true if Rex::Socket::RangeWalker.new("255.255.255.255-255.255.255.255").include? ip_x
		return false
	end

	def ipv4_validator(addr)
		return false unless addr.kind_of? String
		addr =~ /^(?:(?:25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\.){3}(?:25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)$/
	end

	# Takes a space-delimited set of ips and ranges, and subjects
	# them to RangeWalker for validation. Returns true or false.
	def validate_ips(ips)
		ret = true
		begin
			ips.split(' ').each {|ip|
				unless Rex::Socket::RangeWalker.new(ip).ranges
					ret = false
					break
				end
				}
		rescue
			ret = false
		end
		return ret
	end


	#
	# Determines if the database is functional
	#
	def check
		res = Host.find(:first)
	end


	def default_workspace
		Workspace.default
	end

	def find_workspace(name)
		Workspace.find_by_name(name)
	end

	#
	# Creates a new workspace in the database
	#
	def add_workspace(name)
		Workspace.find_or_create_by_name(name)
	end

	def workspaces
		Workspace.find(:all)
	end

	#
	# Wait for all pending write to finish
	#
	def sync
		task = queue( Proc.new { } )
		task.wait
	end

	#
	# Find a host.  Performs no database writes.
	#
	def get_host(opts)
		if opts.kind_of? Host
			return opts
		elsif opts.kind_of? String
			raise RuntimeError, "This invokation of get_host is no longer supported: #{caller}"
		else
			address = opts[:addr] || opts[:address] || opts[:host] || return
			return address if address.kind_of? Host
		end
		wspace = opts.delete(:workspace) || workspace
		host   = wspace.hosts.find_by_address(address)
		return host
	end

	#
	# Exactly like report_host but waits for the database to create a host and returns it.
	#
	def find_or_create_host(opts)
		report_host(opts.merge({:wait => true}))
	end

	#
	# Report a host's attributes such as operating system and service pack
	#
	# The opts parameter MUST contain
	#	:host       -- the host's ip address
	#
	# The opts parameter can contain:
	#	:state      -- one of the Msf::HostState constants
	#	:os_name    -- one of the Msf::OperatingSystems constants
	#	:os_flavor  -- something like "XP" or "Gentoo"
	#	:os_sp      -- something like "SP2"
	#	:os_lang    -- something like "English", "French", or "en-US"
	#	:arch       -- one of the ARCH_* constants
	#	:mac        -- the host's MAC address
	#
	def report_host(opts)
		return if not active
		addr = opts.delete(:host) || return

		# Sometimes a host setup through a pivot will see the address as "Remote Pipe"
		if addr.eql? "Remote Pipe"
			return
		end

		# Ensure the host field updated_at is changed on each report_host()
		if addr.kind_of? Host
			queue( Proc.new { addr.updated_at = addr.created_at; addr.save! } )
			return addr
		end

		addr = normalize_host(addr)

		wait = opts.delete(:wait)
		wspace = opts.delete(:workspace) || workspace

		if opts[:host_mac]
			opts[:mac] = opts.delete(:host_mac)
		end

		unless ipv4_validator(addr)
			raise ::ArgumentError, "Invalid IP address in report_host(): #{addr}"
		end

		ret = {}
		task = queue( Proc.new {
			if opts[:comm] and opts[:comm].length > 0
				host = wspace.hosts.find_or_initialize_by_address_and_comm(addr, opts[:comm])
			else
				host = wspace.hosts.find_or_initialize_by_address(addr)
			end

			opts.each { |k,v|
				if (host.attribute_names.include?(k.to_s))
					host[k] = v unless host.attribute_locked?(k.to_s)
				else
					dlog("Unknown attribute for Host: #{k}")
				end
			}
			host.info = host.info[0,Host.columns_hash["info"].limit] if host.info

			# Set default fields if needed
			host.state       = HostState::Alive if not host.state
			host.comm        = ''        if not host.comm
			host.workspace   = wspace    if not host.workspace

			# Always save the host, helps track updates
			msf_import_timestamps(opts,host)
			host.save!

			ret[:host] = host
		} )
		if wait
			return nil if task.wait != :done
			return ret[:host]
		end
		return task
	end

	#
	# Iterates over the hosts table calling the supplied block with the host
	# instance of each entry.
	#
	def each_host(wspace=workspace, &block)
		wspace.hosts.each do |host|
			block.call(host)
		end
	end

	#
	# Returns a list of all hosts in the database
	#
	def hosts(wspace = workspace, only_up = false, addresses = nil)
		conditions = {}
		conditions[:state] = [Msf::HostState::Alive, Msf::HostState::Unknown] if only_up
		conditions[:address] = addresses if addresses
		wspace.hosts.all(:conditions => conditions, :order => :address)
	end



	def find_or_create_service(opts)
		report_service(opts.merge({:wait => true}))
	end

	#
	# Record a service in the database.
	#
	# opts must contain
	#	:host  -- the host where this service is running
	#	:port  -- the port where this service listens
	#	:proto -- the transport layer protocol (e.g. tcp, udp)
	#
	# opts may contain
	#	:name  -- the application layer protocol (e.g. ssh, mssql, smb)
	#
	def report_service(opts)
		return if not active
		addr  = opts.delete(:host) || return
		hname = opts.delete(:host_name)
		hmac  = opts.delete(:host_mac)

		wait = opts.delete(:wait)
		wspace = opts.delete(:workspace) || workspace

		hopts = {:workspace => wspace, :host => addr}
		hopts[:name] = hname if hname
		hopts[:mac]  = hmac  if hmac
		report_host(hopts)

		ret  = {}

		task = queue(Proc.new {
			host = get_host(:workspace => wspace, :address => addr)
			if host
				host.updated_at = host.created_at
				host.state      = HostState::Alive
				host.save!
			end

			proto = opts[:proto] || 'tcp'
			opts[:name].downcase! if (opts[:name])

			service = host.services.find_or_initialize_by_port_and_proto(opts[:port].to_i, proto)
			opts.each { |k,v|
				if (service.attribute_names.include?(k.to_s))
					service[k] = v
				else
					dlog("Unknown attribute for Service: #{k}")
				end
			}
			if (service.state == nil)
				service.state = ServiceState::Open
			end
			if (service and service.changed?)
				msf_import_timestamps(opts,service)
				service.save!
			end
			ret[:service] = service
		})
		if wait
			return nil if task.wait() != :done
			return ret[:service]
		end
		return task
	end

	def get_service(wspace, host, proto, port)
		host = get_host(:workspace => wspace, :address => host)
		return if not host
		return host.services.find_by_proto_and_port(proto, port)
	end

	#
	# Iterates over the services table calling the supplied block with the
	# service instance of each entry.
	#
	def each_service(wspace=workspace, &block)
		services(wspace).each do |service|
			block.call(service)
		end
	end

	#
	# Returns a list of all services in the database
	#
	def services(wspace = workspace, only_up = false, proto = nil, addresses = nil, ports = nil, names = nil)
		conditions = {}
		conditions[:state] = [ServiceState::Open] if only_up
		conditions[:proto] = proto if proto
		conditions["hosts.address"] = addresses if addresses
		conditions[:port] = ports if ports
		conditions[:name] = names if names
		wspace.services.all(:include => :host, :conditions => conditions, :order => "hosts.address, port")
	end


	def get_client(opts)
		wspace = opts.delete(:workspace) || workspace
		host   = get_host(:workspace => wspace, :host => opts[:host]) || return
		client = host.clients.find(:first, :conditions => {:ua_string => opts[:ua_string]})
		return client
	end

	def find_or_create_client(opts)
		report_client(opts.merge({:wait => true}))
	end

	#
	# Report a client running on a host.
	#
	# opts must contain
	#   :ua_string  -- the value of the User-Agent header
	#   :host       -- the host where this client connected from, can be an ip address or a Host object
	#
	# opts can contain
	#   :ua_name    -- one of the Msf::HttpClients constants
	#   :ua_ver     -- detected version of the given client
	#   :campaign   -- an id or Campaign object
	#
	# Returns a Client.
	#
	def report_client(opts)
		return if not active
		addr = opts.delete(:host) || return
		wspace = opts.delete(:workspace) || workspace
		report_host(:workspace => wspace, :host => addr)
		wait = opts.delete(:wait)

		ret = {}
		task = queue(Proc.new {
			host = get_host(:workspace => wspace, :host => addr)
			client = host.clients.find_or_initialize_by_ua_string(opts[:ua_string])

			campaign = opts.delete(:campaign)
			if campaign
				case campaign
				when Campaign
					opts[:campaign_id] = campaign.id
				else
					opts[:campaign_id] = campaign
				end
			end

			opts.each { |k,v|
				if (client.attribute_names.include?(k.to_s))
					client[k] = v
				else
					dlog("Unknown attribute for Client: #{k}")
				end
			}
			if (client and client.changed?)
				client.save!
			end
			ret[:client] = client
		})
		if wait
			return nil if task.wait() != :done
			return ret[:client]
		end
		return task
	end

	#
	# This method iterates the vulns table calling the supplied block with the
	# vuln instance of each entry.
	#
	def each_vuln(wspace=workspace,&block)
		wspace.vulns.each do |vulns|
			block.call(vulns)
		end
	end

	#
	# This methods returns a list of all vulnerabilities in the database
	#
	def vulns(wspace=workspace)
		wspace.vulns
	end

	#
	# This methods returns a list of all credentials in the database
	#
	def creds(wspace=workspace)
		Cred.find(
			:all,
			:include => {:service => :host}, # That's some magic right there.
			:conditions => ["hosts.workspace_id = ?", wspace.id]
		)
	end

	#
	# This method returns a list of all exploited hosts in the database.
	#
	def exploited_hosts(wspace=workspace)
		wspace.exploited_hosts
	end

	#
	# This method iterates the notes table calling the supplied block with the
	# note instance of each entry.
	#
	def each_note(wspace=workspace, &block)
		wspace.notes.each do |note|
			block.call(note)
		end
	end

	#
	# Find or create a note matching this type/data
	#
	def find_or_create_note(opts)
		report_note(opts.merge({:wait => true}))
	end

	#
	# Report a Note to the database.  Notes can be tied to a Workspace, Host, or Service.
	#
	# opts MUST contain
	#  :data  -- whatever it is you're making a note of
	#  :type  -- The type of note, e.g. smb_peer_os
	#
	# opts can contain
	#  :workspace  -- the workspace to associate with this Note
	#  :host       -- an IP address or a Host object to associate with this Note
	#  :service    -- a Service object to associate with this Note
	#  :port       -- along with :host and proto, a service to associate with this Note
	#  :proto      -- along with :host and port, a service to associate with this Note
	#  :update     -- what to do in case a similar Note exists, see below
	#
	# The :update option can have the following values:
	#  :unique       -- allow only a single Note per +host+/+type+ pair
	#  :unique_data  -- like :uniqe, but also compare +data+
	#  :insert       -- always insert a new Note even if one with identical values exists
	#
	# If the provided :host is an IP address and does not exist in the
	# database, it will be created.  If :workspace, :host and :service are all
	# omitted, the new Note will be associated with the current workspace.
	#
	def report_note(opts)
		return if not active
		wait = opts.delete(:wait)
		wspace = opts.delete(:workspace) || workspace
		seen = opts.delete(:seen) || false
		crit = opts.delete(:critical) || false
		host = nil
		addr = nil
		# Report the host so it's there for the Proc to use below
		if opts[:host]
			if opts[:host].kind_of? Host
				host = opts[:host]
			else
				report_host({:workspace => wspace, :host => opts[:host]})
				addr = normalize_host(opts[:host])
			end
			# Do the same for a service if that's also included.
			if (opts[:port])
				proto = nil
				sname = nil
				case opts[:proto].to_s.downcase # Catch incorrect usages
				when 'tcp','udp'
					proto = opts[:proto]
					sname = opts[:sname] if opts[:sname]
				when 'dns','snmp','dhcp'
					proto = 'udp'
					sname = opts[:proto]
				else
					proto = 'tcp'
					sname = opts[:proto]
				end
				sopts = {
					:workspace => wspace,
					:host  => opts[:host],
					:port  => opts[:port],
					:proto => proto
				}
				sopts[:name] = sname if sname
				report_service(sopts)
			end
		end
		# Update Modes can be :unique, :unique_data, :insert
		mode = opts[:update] || :unique

		ret = {}
		task = queue(Proc.new {
			if addr and not host
				host = get_host(:workspace => wspace, :host => addr)
			end
			if host and (opts[:port] and opts[:proto])
				service = get_service(wspace, host, opts[:proto], opts[:port])
			elsif opts[:service] and opts[:service].kind_of? Service
				service = opts[:service]
			end

			if host
				host.updated_at = host.created_at
				host.state      = HostState::Alive
				host.save!
			end

			ntype  = opts.delete(:type) || opts.delete(:ntype) || (raise RuntimeError, "A note :type or :ntype is required")
			data   = opts[:data] || (raise RuntimeError, "Note :data is required")
			method = nil
			args   = []
			note   = nil

			conditions = { :ntype => ntype }
			conditions[:host_id] = host[:id] if host
			conditions[:service_id] = service[:id] if service

			notes = wspace.notes.find(:all, :conditions => conditions)

			case mode
			when :unique
				# Only one note of this type should exist, make a new one if it
				# isn't there. If it is, grab it and overwrite its data.
				if notes.empty?
					note = wspace.notes.new(conditions)
				else
					note = notes[0]
				end
				note.data = data
			when :unique_data
				# Don't make a new Note with the same data as one that already
				# exists for the given: type and (host or service)
				notes.each do |n|
					# Compare the deserialized data from the table to the raw
					# data we're looking for.  Because of the serialization we
					# can't do this easily or reliably in SQL.
					if n.data == data
						note = n
						break
					end
				end
				if not note
					# We didn't find one with the data we're looking for, make
					# a new one.
					note = wspace.notes.new(conditions.merge(:data => data))
				end
			else
				# Otherwise, assume :insert, which means always make a new one
				note = wspace.notes.new
				if host
					note.host_id = host[:id]
				end
				if opts[:service] and opts[:service].kind_of? Service
					note.service_id = opts[:service][:id]
				end
				note.seen     = seen
				note.critical = crit
				note.ntype    = ntype
				note.data     = data
			end
			msf_import_timestamps(opts,note)
			note.save!

			ret[:note] = note
		})
		if wait
			return nil if task.wait() != :done
			return ret[:note]
		end
		return task
	end

	#
	# This methods returns a list of all notes in the database
	#
	def notes(wspace=workspace)
		wspace.notes
	end

	# This is only exercised by MSF3 XML importing for now. Needs the wait
	# conditions and return hash as well.
	def report_host_tag(opts)
		name = opts.delete(:name)
		raise DBImportError.new("Missing required option :name") unless name
		addr = opts.delete(:addr) 
		raise DBImportError.new("Missing required option :addr") unless addr
		wspace = opts.delete(:wspace)
		raise DBImportError.new("Missing required option :wspace") unless wspace

		host = nil
		report_host(:workspace => wspace, :address => addr)

		task = queue( Proc.new {
			host = get_host(:workspace => wspace, :address => addr)
			desc = opts.delete(:desc)
			summary = opts.delete(:summary)
			detail = opts.delete(:detail)
			crit = opts.delete(:crit)
			possible_tag = Tag.find(:all,
				:include => :hosts,
				:conditions => ["hosts.workspace_id = ? and tags.name = ?",
					wspace.id,
					name
				]
			).first
			tag = possible_tag || Tag.new
			tag.name = name
			tag.desc = desc
			tag.report_summary = !!summary
			tag.report_detail = !!detail
			tag.critical = !!crit
			tag.hosts = tag.hosts | [host]
			tag.save! if tag.changed?
		})
		return task
	end

	# report_auth_info used to create a note, now it creates
	# an entry in the creds table. It's much more akin to
	# report_vuln() now.
	#
	# opts must contain
	#	:host    -- an IP address 
	#	:port    -- a port number 
	#
	# opts can contain
	#	:user  -- the username
	#	:pass  -- the password, or path to ssh_key
	#	:ptype  -- the type of password (password, hash, or ssh_key)
	#   :proto -- a transport name for the port
	#   :sname -- service name
	#	:active -- by default, a cred is active, unless explicitly false
	#	:proof  -- data used to prove the account is actually active.
	#
	# Sources: Credentials can be sourced from another credential, or from
	# a vulnerability. For example, if an exploit was used to dump the
	# smb_hashes, and this credential comes from there, the source_id would
	# be the Vuln id (as reported by report_vuln) and the type would be "Vuln".
	#
	#	:source_id   -- The Vuln or Cred id of the source of this cred.
	#	:source_type -- Either Vuln or Cred
	#
	# TODO: This is written somewhat host-centric, when really the 
	# Service is the thing. Need to revisit someday.
	def report_auth_info(opts={})
		return if not active
		raise ArgumentError.new("Missing required option :host") if opts[:host].nil? 
		raise ArgumentError.new("Invalid address for :host") unless validate_ips(opts[:host])
		raise ArgumentError.new("Missing required option :port") if opts[:port].nil?
		host = opts.delete(:host)
		ptype = opts.delete(:type) || "password"
		token = [opts.delete(:user), opts.delete(:pass)]
		sname = opts.delete(:sname)
		port = opts.delete(:port)
		proto = opts.delete(:proto) || "tcp"
		proof = opts.delete(:proof)
		source_id = opts.delete(:source_id)
		source_type = opts.delete(:source_type)
		duplicate_ok = opts.delete(:duplicate_ok)
		# Nil is true for active.
		active = (opts[:active] || opts[:active].nil?) ? true : false

		wait = opts.delete(:wait)
		wspace = opts.delete(:workspace) || workspace

		# Service management; assume the user knows what
		# he's talking about.
		unless service = get_service(wspace, host, proto, port)
			report_service(:host => host, :port => port, :proto => proto, :name => sname, :workspace => wspace)
		end

		ret = {}
		task = queue( Proc.new {

			# Get the service
			service ||= get_service(wspace, host, proto, port)

			# If duplicate usernames are okay, find by both user and password (allows
			# for actual duplicates to get modified updated_at, sources, etc)
			if duplicate_ok
				cred = service.creds.find_or_initialize_by_user_and_ptype_and_pass(token[0] || "", ptype, token[1] || "")
			else
				# Create the cred by username only (so we can change passwords) 
				cred = service.creds.find_or_initialize_by_user_and_ptype(token[0] || "", ptype)
			end

			# Update with the password
			cred.pass = (token[1] || "")

			# Annotate the credential
			cred.ptype = ptype
			cred.active = active

			# Update the source ID only if there wasn't already one.
			if source_id and !cred.source_id
				cred.source_id = source_id 
				cred.source_type = source_type if source_type
			end

			# Safe proof (lazy way) -- doesn't chop expanded
			# characters correctly, but shouldn't ever be a problem.
			unless proof.nil?
				proof = Rex::Text.to_hex_ascii(proof) 
				proof = proof[0,4096]
			end
			cred.proof = proof

			# Update the timestamp
			if cred.changed?
				msf_import_timestamps(opts,cred)
				cred.save!
			end

			# Ensure the updated_at is touched any time report_auth_info is called
			# except when it's set explicitly (as it is for imports)
			unless opts[:updated_at] || opts["updated_at"]
				cred.updated_at = Time.now.utc
				cred.save!
			end

			ret[:cred] = cred
		})
		if wait
			return nil if task.wait() != :done
			return ret[:cred]
		end
		return task
	end

	alias :report_cred :report_auth_info
	alias :report_auth :report_auth_info

	#
	# Find or create a credential matching this type/data
	#
	def find_or_create_cred(opts)
		report_auth_info(opts.merge({:wait => true}))
	end

	#
	# This method iterates the creds table calling the supplied block with the
	# cred instance of each entry.
	#
	def each_cred(wspace=workspace,&block)
		wspace.creds.each do |cred|
			block.call(cred)
		end
	end

	def each_exploited_host(wspace=workspace,&block)
		wspace.exploited_hosts.each do |eh|
			block.call(eh)
		end
	end

	#
	# Find or create a vuln matching this service/name
	#
	def find_or_create_vuln(opts)
		report_vuln(opts.merge({:wait => true}))
	end

	#
	# opts must contain
	#	:host  -- the host where this vulnerability resides
	#	:name  -- the scanner-specific id of the vuln (e.g. NEXPOSE-cifs-acct-password-never-expires)
	#
	# opts can contain
	#	:info  -- a human readable description of the vuln, free-form text
	#	:refs  -- an array of Ref objects or string names of references
	#
	def report_vuln(opts)
		return if not active
		raise ArgumentError.new("Missing required option :host") if opts[:host].nil?
		raise ArgumentError.new("Deprecated data column for vuln, use .info instead") if opts[:data]
		name = opts[:name] || return
		info = opts[:info]
		wait = opts.delete(:wait)
		wspace = opts.delete(:workspace) || workspace
		rids = nil
		if opts[:refs]
			rids = []
			opts[:refs].each do |r|
				if r.respond_to? :ctx_id
					r = r.ctx_id + '-' + r.ctx_val
				end
				rids << find_or_create_ref(:name => r)
			end
		end

		host = nil
		addr = nil
		if opts[:host].kind_of? Host
			host = opts[:host]
		else
			report_host({:workspace => wspace, :host => opts[:host]})
			addr = normalize_host(opts[:host])
		end

		ret = {}
		task = queue( Proc.new {
			if host
				host.updated_at = host.created_at
				host.state      = HostState::Alive
				host.save!
			else
				host = get_host(:workspace => wspace, :address => addr)
			end

			if info
				vuln = host.vulns.find_or_initialize_by_name_and_info(name, info, :include => :refs)
			else
				vuln = host.vulns.find_or_initialize_by_name(name, :include => :refs)
			end

			if opts[:port]
				proto = nil
				case opts[:proto].to_s.downcase # Catch incorrect usages, as in report_note
				when 'tcp','udp'
					proto = opts[:proto]
				when 'dns','snmp','dhcp'
					proto = 'udp'
					sname = opts[:proto]
				else
					proto = 'tcp'
					sname = opts[:proto]
				end
				vuln.service = host.services.find_or_create_by_port_and_proto(opts[:port], proto)
			end

			if rids
				vuln.refs << (rids - vuln.refs)
			end

			if vuln.changed?
				msf_import_timestamps(opts,vuln)
				vuln.save!
			end
			ret[:vuln] = vuln
		})
		if wait
			return nil if task.wait() != :done
			return ret[:vuln]
		end
		return task
	end

	def get_vuln(wspace, host, service, name, data='')
		raise RuntimeError, "Not workspace safe: #{caller.inspect}"
		vuln = nil
		if (service)
			vuln = Vuln.find(:first, :conditions => [ "name = ? and service_id = ? and host_id = ?", name, service.id, host.id])
		else
			vuln = Vuln.find(:first, :conditions => [ "name = ? and host_id = ?", name, host.id])
		end

		return vuln
	end

	#
	# Find or create a reference matching this name
	#
	def find_or_create_ref(opts)
		ret = {}
		ret[:ref] = get_ref(opts[:name])
		return ret[:ref] if ret[:ref]

		task = queue(Proc.new {
			ref = Ref.find_or_initialize_by_name(opts[:name])
			if ref and ref.changed?
				ref.save!
			end
			ret[:ref] = ref
		})
		return nil if task.wait() != :done
		return ret[:ref]
	end
	def get_ref(name)
		Ref.find_by_name(name)
	end

	def report_exploit(opts={})
		return if not active
		raise ArgumentError.new("Missing required option :host") if opts[:host].nil?
		wait   = opts[:wait]
		wspace = opts.delete(:workspace) || workspace
		host = nil
		addr = nil
		sname = opts.delete(:sname)
		port = opts.delete(:port)
		proto = opts.delete(:proto) || "tcp"
		name = opts.delete(:name)
		payload = opts.delete(:payload)
		session_uuid = opts.delete(:session_uuid) 

		if opts[:host].kind_of? Host
			host = opts[:host]
		else
			report_host({:workspace => wspace, :host => opts[:host]})
			addr = normalize_host(opts[:host])
		end

		if opts[:service].kind_of? Service
			service = opts[:service]
		elsif port
			report_service(:host => host, :port => port, :proto => proto, :name => sname)
			service = get_service(wspace, host, proto, port)
		else
			service = nil
		end

		ret = {}

		task = queue(
			Proc.new {
				if host
					host.updated_at = host.created_at
					host.state      = HostState::Alive
					host.save!
				else
					host = get_host(:workspace => wspace, :address => addr)
				end
				exploit_info = {
					:workspace => wspace,
					:host_id => host.id,
					:name => name,
					:payload => payload,
				}
				exploit_info[:service_id] = service.id if service
				exploit_info[:session_uuid] = session_uuid if session_uuid 
				exploit_record = ExploitedHost.create(exploit_info)
				exploit_record.save!

				ret[:exploit] = exploit_record
			}
		)

		if wait
			return nil if task.wait() != :done
			return ret[:exploit]
		end
		return task
		
	end


	#
	# Deletes a host and associated data matching this address/comm
	#
	def del_host(wspace, address, comm='')
		host = wspace.hosts.find_by_address_and_comm(address, comm)
		host.destroy if host
	end

	#
	# Deletes a port and associated vulns matching this port
	#
	def del_service(wspace, address, proto, port, comm='')

		host = get_host(:workspace => wspace, :address => address)
		return unless host

		host.services.all(:conditions => {:proto => proto, :port => port}).each { |s| s.destroy }
	end

	#
	# Find a reference matching this name
	#
	def has_ref?(name)
		Ref.find_by_name(name)
	end

	#
	# Find a vulnerability matching this name
	#
	def has_vuln?(name)
		Vuln.find_by_name(name)
	end

	#
	# Look for an address across all comms
	#
	def has_host?(wspace,addr)
		wspace.hosts.find_by_address(addr)
	end

	def events(wspace=workspace)
		wspace.events.find :all, :order => 'created_at ASC'
	end

	def report_event(opts = {})
		return if not active
		wspace = opts.delete(:workspace) || workspace
		uname  = opts.delete(:username)

		if opts[:host]
			report_host(:workspace => wspace, :host => opts[:host])
		end
		framework.db.queue(Proc.new {
			opts[:host] = get_host(:workspace => wspace, :host => opts[:host]) if opts[:host]
			Event.create(opts.merge(:workspace_id => wspace[:id], :username => uname))
		})
	end

	#
	# Loot collection
	#
	#
	# This method iterates the loot table calling the supplied block with the
	# instance of each entry.
	#
	def each_loot(wspace=workspace, &block)
		wspace.loots.each do |note|
			block.call(note)
		end
	end

	#
	# Find or create a loot matching this type/data
	#
	def find_or_create_loot(opts)
		report_loot(opts.merge({:wait => true}))
	end

	def report_loot(opts)
		return if not active
		wait = opts.delete(:wait)
		wspace = opts.delete(:workspace) || workspace
		path = opts.delete(:path) || (raise RuntimeError, "A loot :path is required")

		host = nil
		addr = nil

		# Report the host so it's there for the Proc to use below
		if opts[:host]
			if opts[:host].kind_of? Host
				host = opts[:host]
			else
				report_host({:workspace => wspace, :host => opts[:host]})
				addr = normalize_host(opts[:host])
			end
		end

		ret = {}
		task = queue(Proc.new {

			if addr and not host
				host = get_host(:workspace => wspace, :host => addr)
			end

			ltype  = opts.delete(:type) || opts.delete(:ltype) || (raise RuntimeError, "A loot :type or :ltype is required")
			ctype  = opts.delete(:ctype) || opts.delete(:content_type) || 'text/plain'
			name   = opts.delete(:name)
			info   = opts.delete(:info)
			data   = opts[:data]
			loot   = wspace.loots.new

			if host
				loot.host_id = host[:id]
			end
			if opts[:service] and opts[:service].kind_of? Service
				loot.service_id = opts[:service][:id]
			end

			loot.path  = path
			loot.ltype = ltype
			loot.content_type = ctype
			loot.data  = data
			loot.name  = name if name
			loot.info  = info if info
			msf_import_timestamps(opts,loot)
			loot.save!

			if !opts[:created_at]
				if host
					host.updated_at = host.created_at
					host.state      = HostState::Alive
					host.save!
				end
			end

			ret[:loot] = loot
		})

		if wait
			return nil if task.wait() != :done
			return ret[:loot]
		end
		return task
	end

	#
	# This methods returns a list of all loot in the database
	#
	def loots(wspace=workspace)
		wspace.loots
	end

	#
	# Find or create a task matching this type/data
	#
	def find_or_create_task(opts)
		report_task(opts.merge({:wait => true}))
	end

	def report_task(opts)
		return if not active
		wait = opts.delete(:wait)
		wspace = opts.delete(:workspace) || workspace
		path = opts.delete(:path) || (raise RuntimeError, "A task :path is required")

		ret = {}
		this_task = queue(Proc.new {

			user      = opts.delete(:user)
			desc      = opts.delete(:desc)
			error     = opts.delete(:error)
			info      = opts.delete(:info)
			mod       = opts.delete(:mod)
			options   = opts.delete(:options)
			prog      = opts.delete(:prog)
			result    = opts.delete(:result)
			completed_at = opts.delete(:completed_at)
			task      = wspace.tasks.new

			task.created_by = user
			task.description = desc
			task.error = error if error
			task.info = info
			task.module = mod
			task.options = options
			task.path = path
			task.progress = prog
			task.result = result if result
			msf_import_timestamps(opts,task)
			# Having blank completed_ats, while accurate, will cause unstoppable tasks.
			if completed_at.nil? || completed_at.empty?
				task.completed_at = opts[:updated_at]
			else
				task.completed_at = completed_at
			end
			task.save!

			ret[:task] = task
		})

		if wait
			return nil if this_task.wait() != :done
			return ret[:task]
		end
		return this_task
	end

	#
	# This methods returns a list of all tasks in the database
	#
	def tasks(wspace=workspace)
		wspace.tasks
	end


	#
	# Find or create a task matching this type/data
	#
	def find_or_create_report(opts)
		report_report(opts.merge({:wait => true}))
	end

	def report_report(opts)
		return if not active
		wait = opts.delete(:wait)
		wspace = opts.delete(:workspace) || workspace
		path = opts.delete(:path) || (raise RuntimeError, "A report :path is required")

		ret = {}
		this_task = queue(Proc.new {

			user      = opts.delete(:user)
			options   = opts.delete(:options)
			rtype     = opts.delete(:rtype)
			report    = wspace.reports.new

			report.created_by = user
			report.options = options
			report.rtype = rtype
			report.path = path
			msf_import_timestamps(opts,report)
			report.save!

			ret[:task] = report
		})

		if wait
			return nil if this_task.wait() != :done
			return ret[:task]
		end
		return this_task
	end

	#
	# This methods returns a list of all reports in the database
	#
	def reports(wspace=workspace)
		wspace.reports
	end

	#
	# WMAP
	# Support methods
	#

	#
	# Report a Web Site to the database.  WebSites must be tied to an existing Service
	#
	# opts MUST contain
	#  :service* -- the service object this site should be associated with
	#  :vhost    -- the virtual host name for this particular web site`
	
	# If service is NOT specified, the following values are mandatory
	#  :host     -- the ip address of the server hosting the web site
	#  :port     -- the port number of the associated web site
	#  :ssl      -- whether or not SSL is in use on this port
	#
	# These values will be used to create new host and service records
	
	#
	# opts can contain
	#  :options    -- a hash of options for accessing this particular web site

	# 
	# Duplicate records for a given host, port, vhost combination will be overwritten
	#
	
	def report_web_site(opts)
		return if not active
		wait = opts.delete(:wait)
		wspace = opts.delete(:workspace) || workspace
		vhost  = opts.delete(:vhost)

		addr = nil
		port = nil
		name = nil		
		serv = nil
		
		if opts[:service] and opts[:service].kind_of?(Service)
			serv = opts[:service]
		else
			addr = opts[:host]
			port = opts[:port]
			name = opts[:ssl] ? 'https' : 'http'
			if not (addr and port)
				raise ArgumentError, "report_web_site requires service OR host/port/ssl"
			end
			
			# Force addr to be the address and not hostname
			addr = Rex::Socket.getaddress(addr)
		end

		ret = {}
		task = queue(Proc.new {
			
			host = serv ? serv.host : find_or_create_host(
				:workspace => wspace,
				:host      => addr, 
				:state     => Msf::HostState::Alive
			)
			
			if host.name.to_s.empty?
				host.name = vhost
				host.save!
			end
			
			serv = serv ? serv : find_or_create_service(
				:workspace => wspace,
				:host      => host, 
				:port      => port, 
				:proto     => 'tcp',
				:state     => 'open'
			)
			
			# Change the service name if it is blank or it has
			# been explicitly specified.
			if opts.keys.include?(:ssl) or serv.name.to_s.empty?
				name = opts[:ssl] ? 'https' : 'http'
				serv.name = name
				serv.save!
			end
			
			host.updated_at = host.created_at
			host.state      = HostState::Alive
			host.save!
	
			vhost ||= host.address

			site = WebSite.find_or_initialize_by_vhost_and_service_id(vhost, serv[:id])
			site.options = opts[:options] if opts[:options]
			
			# XXX:
			msf_import_timestamps(opts, site)
			site.save!

			ret[:web_site] = site
		})
		if wait
			return nil if task.wait() != :done
			return ret[:web_site]
		end
		return task
	end


	#
	# Report a Web Page to the database.  WebPage must be tied to an existing Web Site
	#
	# opts MUST contain
	#  :web_site* -- the web site object that this page should be associated with
	#  :path      -- the virtual host name for this particular web site
	#  :code      -- the http status code from requesting this page
	#  :headers   -- this is a HASH of headers (lowercase name as key) of ARRAYs of values
	#  :body      -- the document body of the server response
	#  :query     -- the query string after the path 	
	
	# If web_site is NOT specified, the following values are mandatory
	#  :host     -- the ip address of the server hosting the web site
	#  :port     -- the port number of the associated web site
	#  :vhost    -- the virtual host for this particular web site
	#  :ssl      -- whether or not SSL is in use on this port
	#
	# These values will be used to create new host, service, and web_site records
	#
	# opts can contain
	#  :cookie   -- the Set-Cookie headers, merged into a string
	#  :auth     -- the Authorization headers, merged into a string
	#  :ctype    -- the Content-Type headers, merged into a string
	#  :mtime    -- the timestamp returned from the server of the last modification time
	#  :location -- the URL that a redirect points to
	# 
	# Duplicate records for a given web_site, path, and query combination will be overwritten
	#
	
	def report_web_page(opts)
		return if not active
		wait = opts.delete(:wait)
		wspace = opts.delete(:workspace) || workspace
		
		path    = opts[:path]
		code    = opts[:code].to_i
		body    = opts[:body].to_s
		query   = opts[:query].to_s
		headers = opts[:headers]		
		site    = nil
		
		if not (path and code and body and headers)
			raise ArgumentError, "report_web_page requires the path, query, code, body, and headers parameters"
		end
		
		if opts[:web_site] and opts[:web_site].kind_of?(WebSite)
			site = opts.delete(:web_site)
		else
			site = report_web_site(
				:workspace => wspace,
				:host      => opts[:host], :port => opts[:port], 
				:vhost     => opts[:host], :ssl  => opts[:ssl], 
				:wait      => true
			)
			if not site
				raise ArgumentError, "report_web_page was unable to create the associated web site"
			end
		end

		ret = {}
		task = queue(Proc.new {
			page = WebPage.find_or_initialize_by_web_site_id_and_path_and_query(site[:id], path, query)
			page.code     = code
			page.body     = body
			page.headers  = headers	
			page.cookie   = opts[:cookie] if opts[:cookie]
			page.auth     = opts[:auth]   if opts[:auth]
			page.mtime    = opts[:mtime]  if opts[:mtime]
			page.ctype    = opts[:ctype]  if opts[:ctype]
			page.location = opts[:location] if opts[:location]
			msf_import_timestamps(opts, page)
			page.save!

			ret[:web_page] = page
		})
		if wait
			return nil if task.wait() != :done
			return ret[:web_page]
		end
		return task
	end
	
			
	#
	# Report a Web Form to the database.  WebForm must be tied to an existing Web Site
	#
	# opts MUST contain
	#  :web_site* -- the web site object that this page should be associated with
	#  :path      -- the virtual host name for this particular web site
	#  :query     -- the query string that is appended to the path (not valid for GET)
	#  :method    -- the form method, one of GET, POST, or PATH
	#  :params    -- an ARRAY of all parameters and values specified in the form
	#
	# If web_site is NOT specified, the following values are mandatory
	#  :host     -- the ip address of the server hosting the web site
	#  :port     -- the port number of the associated web site
	#  :vhost    -- the virtual host for this particular web site
	#  :ssl      -- whether or not SSL is in use on this port
	#
	# 
	# Duplicate records for a given web_site, path, method, and params combination will be overwritten
	#
	
	def report_web_form(opts)
		return if not active
		wait = opts.delete(:wait)
		wspace = opts.delete(:workspace) || workspace
		
		path    = opts[:path]
		meth    = opts[:method].to_s.upcase
		para    = opts[:params]
		quer    = opts[:query].to_s
		site    = nil

		if not (path and meth)
			raise ArgumentError, "report_web_form requires the path and method parameters"
		end
		
		if not %W{GET POST PATH}.include?(meth)
			raise ArgumentError, "report_web_form requires the method to be one of GET, POST, PATH"
		end

		if opts[:web_site] and opts[:web_site].kind_of?(WebSite)
			site = opts.delete(:web_site)
		else
			site = report_web_site(
				:workspace => wspace,
				:host      => opts[:host], :port => opts[:port], 
				:vhost     => opts[:host], :ssl  => opts[:ssl], 
				:wait      => true
			)
			if not site
				raise ArgumentError, "report_web_form was unable to create the associated web site"
			end
		end

		ret = {}
		task = queue(Proc.new {
		
			# Since one of our serialized fields is used as a unique parameter, we must do the final
			# comparisons through ruby and not SQL.
			
			form = nil
			WebForm.find_all_by_web_site_id_and_path_and_method_and_query(site[:id], path, meth, quer).each do |xform|
				if xform.params == para
					form = xform
					break
				end 
			end

			if not form
				form = WebForm.new
				form.web_site_id = site[:id]
				form.path        = path
				form.method      = meth
				form.params      = para
				form.query       = quer
			end 
			
			msf_import_timestamps(opts, form)
			form.save!

			ret[:web_form] = form
		})
		if wait
			return nil if task.wait() != :done
			return ret[:web_form]
		end
		return task
	end


	#
	# Report a Web Vuln to the database.  WebVuln must be tied to an existing Web Site
	#
	# opts MUST contain
	#  :web_site* -- the web site object that this page should be associated with
	#  :path      -- the virtual host name for this particular web site
	#  :query     -- the query string appended to the path (not valid for GET method flaws)
	#  :method    -- the form method, one of GET, POST, or PATH
	#  :params    -- an ARRAY of all parameters and values specified in the form
	#  :pname     -- the specific field where the vulnerability occurs
	#  :proof     -- the string showing proof of the vulnerability
	#  :risk      -- an INTEGER value from 0 to 5 indicating the risk (5 is highest)
	#  :name      -- the string indicating the type of vulnerability
	#
	# If web_site is NOT specified, the following values are mandatory
	#  :host     -- the ip address of the server hosting the web site
	#  :port     -- the port number of the associated web site
	#  :vhost    -- the virtual host for this particular web site
	#  :ssl      -- whether or not SSL is in use on this port
	#
	# 
	# Duplicate records for a given web_site, path, method, pname, and name combination will be overwritten
	#
	
	def report_web_vuln(opts)
		return if not active
		wait = opts.delete(:wait)
		wspace = opts.delete(:workspace) || workspace
		
		path    = opts[:path]
		meth    = opts[:method]
		para    = opts[:params] || []
		quer    = opts[:query].to_s
		pname   = opts[:pname]
		proof   = opts[:proof]
		risk    = opts[:risk].to_i
		name    = opts[:name].to_s.strip
		blame   = opts[:blame].to_s.strip
		desc    = opts[:description].to_s.strip
		conf    = opts[:confidence].to_i
		cat     = opts[:category].to_s.strip			
		
		site    = nil

		if not (path and meth and proof and pname)
			raise ArgumentError, "report_web_vuln requires the path, method, proof, risk, name, params, and pname parameters. Received #{opts.inspect}"
		end
		
		if not %W{GET POST PATH}.include?(meth)
			raise ArgumentError, "report_web_vuln requires the method to be one of GET, POST, PATH. Received '#{meth}'"
		end
		
		if risk < 0 or risk > 5
			raise ArgumentError, "report_web_vuln requires the risk to be between 0 and 5 (inclusive). Received '#{risk}'"
		end

		if conf < 0 or conf > 100
			raise ArgumentError, "report_web_vuln requires the confidence to be between 1 and 100 (inclusive). Received '#{conf}'"
		end

		if cat.empty?
			raise ArgumentError, "report_web_vuln requires the category to be a valid string"
		end
						
		if name.empty?
			raise ArgumentError, "report_web_vuln requires the name to be a valid string"
		end
		
		if opts[:web_site] and opts[:web_site].kind_of?(WebSite)
			site = opts.delete(:web_site)
		else
			site = report_web_site(
				:workspace => wspace,
				:host      => opts[:host], :port => opts[:port], 
				:vhost     => opts[:host], :ssl  => opts[:ssl], 
				:wait      => true
			)
			if not site
				raise ArgumentError, "report_web_form was unable to create the associated web site"
			end
		end

		ret = {}
		task = queue(Proc.new {
		
			meth = meth.to_s.upcase
			
			vuln = WebVuln.find_or_initialize_by_web_site_id_and_path_and_method_and_pname_and_category_and_query(site[:id], path, meth, pname, cat, quer)
			vuln.name     = name			
			vuln.risk     = risk
			vuln.params   = para
			vuln.proof    = proof.to_s	
			vuln.category = cat
			vuln.blame    = blame
			vuln.description = desc
			vuln.confidence  = conf
			msf_import_timestamps(opts, vuln)
			vuln.save!

			ret[:web_vuln] = vuln
		})
		if wait
			return nil if task.wait() != :done
			return ret[:web_vuln]
		end
		return task
	end

	#
	# WMAP
	# Selected host
	#
	def selected_host
		selhost = WmapTarget.find(:first, :conditions => ["selected != 0"] )
		if selhost
			return selhost.host
		else
			return
		end
	end

	#
	# WMAP
	# Selected port
	#
	def selected_port
		WmapTarget.find(:first, :conditions => ["selected != 0"] ).port
	end

	#
	# WMAP
	# Selected ssl
	#
	def selected_ssl
		WmapTarget.find(:first, :conditions => ["selected != 0"] ).ssl
	end

	#
	# WMAP
	# Selected id
	#
	def selected_id
		WmapTarget.find(:first, :conditions => ["selected != 0"] ).object_id
	end

	#
	# WMAP
	# This method iterates the requests table identifiying possible targets
	# This method wiil be remove on second phase of db merging.
	#
	def each_distinct_target(&block)
		request_distinct_targets.each do |target|
			block.call(target)
		end
	end

	#
	# WMAP
	# This method returns a list of all possible targets available in requests
	# This method wiil be remove on second phase of db merging.
	#
	def request_distinct_targets
		WmapRequest.find(:all, :select => 'DISTINCT host,address,port,ssl')
	end

	#
	# WMAP
	# This method iterates the requests table returning a list of all requests of a specific target
	#
	def each_request_target_with_path(&block)
		target_requests('AND wmap_requests.path IS NOT NULL').each do |req|
			block.call(req)
		end
	end

	#
	# WMAP
	# This method iterates the requests table returning a list of all requests of a specific target
	#
	def each_request_target_with_query(&block)
		target_requests('AND wmap_requests.query IS NOT NULL').each do |req|
			block.call(req)
		end
	end

	#
	# WMAP
	# This method iterates the requests table returning a list of all requests of a specific target
	#
	def each_request_target_with_body(&block)
		target_requests('AND wmap_requests.body IS NOT NULL').each do |req|
			block.call(req)
		end
	end

	#
	# WMAP
	# This method iterates the requests table returning a list of all requests of a specific target
	#
	def each_request_target_with_headers(&block)
		target_requests('AND wmap_requests.headers IS NOT NULL').each do |req|
			block.call(req)
		end
	end

	#
	# WMAP
	# This method iterates the requests table returning a list of all requests of a specific target
	#
	def each_request_target(&block)
		target_requests('').each do |req|
			block.call(req)
		end
	end

	#
	# WMAP
	# This method returns a list of all requests from target
	#
	def target_requests(extra_condition)
		WmapRequest.find(:all, :conditions => ["wmap_requests.host = ? AND wmap_requests.port = ? #{extra_condition}",selected_host,selected_port])
	end

	#
	# WMAP
	# This method iterates the requests table calling the supplied block with the
	# request instance of each entry.
	#
	def each_request(&block)
		requests.each do |request|
			block.call(request)
		end
	end

	#
	# WMAP
	# This method allows to query directly the requests table. To be used mainly by modules
	#
	def request_sql(host,port,extra_condition)
		WmapRequest.find(:all, :conditions => ["wmap_requests.host = ? AND wmap_requests.port = ? #{extra_condition}",host,port])
	end

	#
	# WMAP
	# This methods returns a list of all targets in the database
	#
	def requests
		WmapRequest.find(:all)
	end

	#
	# WMAP
	# This method iterates the targets table calling the supplied block with the
	# target instance of each entry.
	#
	def each_target(&block)
		targets.each do |target|
			block.call(target)
		end
	end

	#
	# WMAP
	# This methods returns a list of all targets in the database
	#
	def targets
		WmapTarget.find(:all)
	end

	#
	# WMAP
	# This methods deletes all targets from targets table in the database
	#
	def delete_all_targets
		WmapTarget.delete_all
	end

	#
	# WMAP
	# Find a target matching this id
	#
	def get_target(id)
		target = WmapTarget.find(:first, :conditions => [ "id = ?", id])
		return target
	end

	#
	# WMAP
	# Create a target
	#
	def create_target(host,port,ssl,sel)
		tar = WmapTarget.create(
				:host => host,
				:address => host,
				:port => port,
				:ssl => ssl,
				:selected => sel
			)
		#framework.events.on_db_target(rec)
	end


	#
	# WMAP
	# Create a request (by hand)
	#
	def create_request(host,port,ssl,meth,path,headers,query,body,respcode,resphead,response)
		req = WmapRequest.create(
				:host => host,
				:address => host,
				:port => port,
				:ssl => ssl,
				:meth => meth,
				:path => path,
				:headers => headers,
				:query => query,
				:body => body,
				:respcode => respcode,
				:resphead => resphead,
				:response => response
			)
		#framework.events.on_db_request(rec)
	end

	#
	# WMAP
	# Quick way to query the database (used by wmap_sql)
	#
	def sql_query(sqlquery)
		ActiveRecord::Base.connection.select_all(sqlquery)
	end


	# Returns a REXML::Document from the given data.
	def rexmlify(data)
		if data.kind_of?(REXML::Document)
			return data
		else
			# Make an attempt to recover from a REXML import fail, since
			# it's better than dying outright.
			begin
				return REXML::Document.new(data)
			rescue REXML::ParseException => e
				dlog("REXML error: Badly formatted XML, attempting to recover. Error was: #{e.inspect}")
				return REXML::Document.new(data.gsub(/([\x00-\x08\x0b\x0c\x0e-\x19\x80-\xff])/){ |x| "\\x%.2x" % x.unpack("C*")[0] })
			end
		end
	end

	# Handles timestamps from Metasploit Express imports.
	def msf_import_timestamps(opts,obj)
		obj.created_at = opts["created_at"] if opts["created_at"]
		obj.created_at = opts[:created_at] if opts[:created_at]
		obj.updated_at = opts["updated_at"] ? opts["updated_at"] : obj.created_at
		obj.updated_at = opts[:updated_at] ? opts[:updated_at] : obj.created_at
		return obj
	end

	##
	#
	# Import methods
	#
	##

	#
	# Generic importer that automatically determines the file type being
	# imported.  Since this looks for vendor-specific strings in the given
	# file, there shouldn't be any false detections, but no guarantees.
	#
	def import_file(args={}, &block)
		filename = args[:filename] || args['filename']
		wspace = args[:wspace] || args['wspace'] || workspace
		@import_filedata            = {}
		@import_filedata[:filename] = filename

		data = ""
		::File.open(filename, 'rb') do |f|
			data = f.read(f.stat.size)
		end

		case data[0,4]
		when "PK\x03\x04"
			data = Zip::ZipFile.open(filename)
		when "\xd4\xc3\xb2\xa1", "\xa1\xb2\xc3\xd4"
			data = PacketFu::PcapFile.new.readfile(filename)
		end
		if block
			import(args.merge(:data => data)) { |type,data| yield type,data }
		else
			import(args.merge(:data => data))
		end

	end

	# A dispatcher method that figures out the data's file type,
	# and sends it off to the appropriate importer. Note that
	# import_file_detect will raise an error if the filetype
	# is unknown.
	def import(args={}, &block)
		data = args[:data] || args['data']
		wspace = args[:wspace] || args['wspace'] || workspace
		ftype = import_filetype_detect(data)
		yield(:filetype, @import_filedata[:type]) if block
		self.send "import_#{ftype}".to_sym, args, &block
	end

	# Returns one of: :nexpose_simplexml :nexpose_rawxml :nmap_xml :openvas_xml
	# :nessus_xml :nessus_xml_v2 :qualys_xml :msf_xml :nessus_nbe :amap_mlog
	# :amap_log :ip_list, :msf_zip, :libpcap
	# If there is no match, an error is raised instead.
	def import_filetype_detect(data)
	
		if data and data.kind_of? Zip::ZipFile
			raise DBImportError.new("The zip file provided is empty.") if data.entries.empty?
			@import_filedata ||= {}
			@import_filedata[:zip_filename] = File.split(data.to_s).last
			@import_filedata[:zip_basename] = @import_filedata[:zip_filename].gsub(/\.zip$/,"")
			@import_filedata[:zip_entry_names] = data.entries.map {|x| x.name}
			@import_filedata[:zip_xml] = @import_filedata[:zip_entry_names].grep(/^(.*)_[0-9]+\.xml$/).first
			@import_filedata[:zip_wspace] = @import_filedata[:zip_xml].to_s.match(/^(.*)_[0-9]+\.xml$/)[1]
			@import_filedata[:type] = "Metasploit ZIP Report"
			if @import_filedata[:zip_xml]
				return :msf_zip
			else
				raise DBImportError.new("The zip file provided is not a Metasploit ZIP report")
			end
		end

		if data and data.kind_of? PacketFu::PcapFile
			raise DBImportError.new("The pcap file provided is empty.") if data.body.empty?
			@import_filedata ||= {}
			@import_filedata[:type] = "Libpcap Packet Capture"
			return :libpcap
		end

		# Text string kinds of data.
		if data and data.to_s.strip.size.zero? 
			raise DBImportError.new("The data provided to the import function was empty")
		end

		di = data.index("\n")
		firstline = data[0, di]
		@import_filedata ||= {}
		if (firstline.index("<NeXposeSimpleXML"))
			@import_filedata[:type] = "NeXpose Simple XML"
			return :nexpose_simplexml
		elsif (firstline.index("<NexposeReport"))
			@import_filedata[:type] = "NeXpose XML Report"
			return :nexpose_rawxml
		elsif (firstline.index("<scanJob>"))
			@import_filedata[:type] = "Retina XML"
			return :retina_xml		
		elsif (firstline.index("<NessusClientData>"))
			@import_filedata[:type] = "Nessus XML (v1)"
			return :nessus_xml
		elsif (firstline.index("<?xml"))
			# it's xml, check for root tags we can handle
			line_count = 0
			data.each_line { |line|
				line =~ /<([a-zA-Z0-9\-\_]+)[ >]/
				case $1
				when "nmaprun"
					@import_filedata[:type] = "Nmap XML"
					return :nmap_xml
				when "openvas-report"
					@import_filedata[:type] = "OpenVAS Report"
					return :openvas_xml
				when "NessusClientData"
					@import_filedata[:type] = "Nessus XML (v1)"
					return :nessus_xml
				when "NessusClientData_v2"
					@import_filedata[:type] = "Nessus XML (v2)"
					return :nessus_xml_v2
				when "SCAN"
					@import_filedata[:type] = "Qualys XML"
					return :qualys_xml
				when /MetasploitExpressV[1234]/
					@import_filedata[:type] = "Metasploit XML"
					return :msf_xml
				when /MetasploitV4/
					@import_filedata[:type] = "Metasploit XML"
					return :msf_xml		
				when /netsparker/
					@import_filedata[:type] = "NetSparker XML"
					return :netsparker_xml			
				when /audits/
					@import_filedata[:type] = "IP360 XML v3"
					return :ip360_xml_v3
				else
					# Give up if we haven't hit the root tag in the first few lines
					break if line_count > 10
				end
				line_count += 1
			}
		elsif (firstline.index("timestamps|||scan_start"))
			@import_filedata[:type] = "Nessus NBE Report"
			# then it's a nessus nbe
			return :nessus_nbe
		elsif (firstline.index("# amap v"))
			# then it's an amap mlog
			@import_filedata[:type] = "Amap Log -m"
			return :amap_mlog
		elsif (firstline.index("amap v"))
			# then it's an amap log
			@import_filedata[:type] = "Amap Log"
			return :amap_log
		elsif (firstline =~ /^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}/)
			# then its an IP list
			@import_filedata[:type] = "IP Address List"
			return :ip_list
		elsif (data[0,1024].index("<netsparker"))
			@import_filedata[:type] = "NetSparker XML"
			return :netsparker_xml				
		elsif (firstline.index("# Metasploit PWDump Export"))
			# then it's a Metasploit PWDump export
			@import_filedata[:type] = "msf_pwdump"
			return :msf_pwdump
		end
		
		raise DBImportError.new("Could not automatically determine file type")
	end

	# Boils down the validate_import_file to a boolean
	def validate_import_file(data)
		begin
			import_filetype_detect(data)
		rescue DBImportError
			return false
		end
		return true
	end

	def import_libpcap_file(args={})
		filename = args[:filename]
		wspace = args[:wspace] || workspace

		data = PacketFu::PcapFile.new.readfile(filename)
		import_libpcap(args.merge(:data => data))
	end

	# The libpcap file format is handled by PacketFu for data
	# extraction. TODO: Make this its own mixin, and possibly
	# extend PacketFu to do better stream analysis on the fly.
	def import_libpcap(args={}, &block)
		data = args[:data]
		wspace = args[:wspace] || workspace
		bl = validate_ips(args[:blacklist]) ? args[:blacklist].split : []
		# seen_hosts is only used for determining when to yield an address. Once we get
		# some packet analysis going, the values will have all sorts of info. The plan
		# is to ru through all the packets as a first pass and report host and service,
		# then, once we have everything parsed, we can reconstruct sessions and ngrep
		# out things like authentication sequences, examine ttl's and window sizes, all
		# kinds of crazy awesome stuff like that.
		seen_hosts = {}
		decoded_packets = 0
		last_count = 0	
		data.body.map {|p| p.data}.each do |p|
			if (decoded_packets >= last_count + 1000) and block
				yield(:pcap_count, decoded_packets) 
				last_count = decoded_packets
			end
			decoded_packets += 1

			pkt = PacketFu::Packet.parse(p) rescue next # Just silently skip bad packets

			next unless pkt.is_ip? # Skip anything that's not IP. Technically, not Ethernet::Ip
			saddr = pkt.ip_saddr
			daddr = pkt.ip_daddr

			# Handle blacklists and obviously useless IP addresses, and report the host.
			next if (bl | [saddr,daddr]).size == bl.size # Both hosts are blacklisted, skip everything.
			unless( bl.include?(saddr) || rfc3330_reserved(saddr))
				yield(:address,saddr) if block and !seen_hosts.keys.include?(saddr) 
				report_host(:workspace => wspace, :host => saddr, :state => Msf::HostState::Alive) unless seen_hosts[saddr]
				seen_hosts[saddr] ||= []

			end
			unless( bl.include?(daddr) || rfc3330_reserved(daddr))
				yield(:address,daddr) if block and !seen_hosts.keys.include?(daddr)
				report_host(:workspace => wspace, :host => daddr, :state => Msf::HostState::Alive) unless seen_hosts[daddr]
				seen_hosts[daddr] ||= [] 
			end

			if pkt.is_tcp? # First pass on TCP packets
				if (pkt.tcp_flags.syn == 1 and pkt.tcp_flags.ack == 1) or # Oh, this kills me
					pkt.tcp_src < 1024 # If it's a low port, assume it's a proper service.
					if seen_hosts[saddr]
						unless seen_hosts[saddr].include? [pkt.tcp_src,"tcp"]
							report_service(
								:workspace => wspace, :host => saddr, 
								:proto => "tcp", :port => pkt.tcp_src, 
								:state => Msf::ServiceState::Open
							) 
							seen_hosts[saddr] << [pkt.tcp_src,"tcp"]
							yield(:service,"%s:%d/%s" % [saddr,pkt.tcp_src,"tcp"])
						end
					end
				end
			elsif pkt.is_udp? # First pass on UDP packets
				if pkt.udp_src == pkt.udp_dst # Very basic p2p detection.
					[saddr,daddr].each do |xaddr|
						if seen_hosts[xaddr]
							unless seen_hosts[xaddr].include? [pkt.udp_src,"udp"]
								report_service(
									:workspace => wspace, :host => xaddr, 
									:proto => "udp", :port => pkt.udp_src, 
									:state => Msf::ServiceState::Open
								)
								seen_hosts[xaddr] << [pkt.udp_src,"udp"]
								yield(:service,"%s:%d/%s" % [xaddr,pkt.udp_src,"udp"])
							end
						end
					end
				elsif pkt.udp_src < 1024 # Probably a service 
					if seen_hosts[saddr]
						unless seen_hosts[saddr].include? [pkt.udp_src,"udp"]
							report_service(
								:workspace => wspace, :host => saddr, 
								:proto => "udp", :port => pkt.udp_src, 
								:state => Msf::ServiceState::Open
							)
							seen_hosts[saddr] << [pkt.udp_src,"udp"]
							yield(:service,"%s:%d/%s" % [saddr,pkt.udp_src,"udp"])
						end
					end
				end
			end # tcp or udp

			inspect_single_packet(pkt,wspace)

		end # data.body.map

		# Right about here, we should have built up some streams for some stream analysis.
		# Not sure what form that will take, but people like shoving many hundreds of
		# thousands of packets through this thing, so it'll need to be memory efficient.

	end

	# Do all the single packet analysis we can while churning through the pcap
	# the first time. Multiple packet inspection will come later, where we can
	# do stream analysis, compare requests and responses, etc.
	def inspect_single_packet(pkt,wspace)
		if pkt.is_tcp? or pkt.is_udp?
			inspect_single_packet_http(pkt,wspace)
		end
	end

	# Checks for packets that are headed towards port 80, are tcp, contain an HTTP/1.0
	# line, contains an Authorization line, contains a b64-encoded credential, and
	# extracts it. Reports this credential and solidifies the service as HTTP.
	def inspect_single_packet_http(pkt,wspace)
		# First, check the server side (data from port 80).
		if pkt.is_tcp? and pkt.tcp_src == 80 and !pkt.payload.nil? and !pkt.payload.empty?
			if pkt.payload =~ /^HTTP\x2f1\x2e[01]/
				http_server_match = pkt.payload.match(/\nServer:\s+([^\r\n]+)[\r\n]/)
				if http_server_match.kind_of?(MatchData) and http_server_match[1]
					report_service(
						:workspace => wspace,
						:host => pkt.ip_saddr,
						:port => pkt.tcp_src,
						:proto => "tcp",
						:name => "http",
						:info => http_server_match[1],
						:state => Msf::ServiceState::Open
					)
					# That's all we want to know from this service.
					return :something_significant
				end
			end
		end

		# Next, check the client side (data to port 80)
		if pkt.is_tcp? and pkt.tcp_dst == 80 and !pkt.payload.nil? and !pkt.payload.empty?
			if pkt.payload.match(/[\x00-\x20]HTTP\x2f1\x2e[10]/)
				auth_match = pkt.payload.match(/\nAuthorization:\s+Basic\s+([A-Za-z0-9=\x2b]+)/)
				if auth_match.kind_of?(MatchData) and auth_match[1]
					b64_cred = auth_match[1] 
				else
					return false
				end
				# If we're this far, we can surmise that at least the client is a web browser,
				# he thinks the server is HTTP and he just made an authentication attempt. At
				# this point, we'll just believe everything the packet says -- validation ought
				# to come later.
				user,pass = b64_cred.unpack("m*").first.split(/:/,2)
				report_service(
					:workspace => wspace,
					:host => pkt.ip_daddr,
					:port => pkt.tcp_dst,
					:proto => "tcp",
					:name => "http"
				)
				report_auth_info(
					:workspace => wspace,
					:host => pkt.ip_daddr,
					:port => pkt.tcp_dst,
					:proto => "tcp",
					:type => "password",
					:active => true, # Once we can build a stream, determine if the auth was successful. For now, assume it is.
					:user => user,
					:pass => pass
				)
				# That's all we want to know from this service.
				return :something_significant
			end
		end
	end

	# 
	# Metasploit PWDump Export
	#
	# This file format is generated by the db_export -f pwdump and
	# the Metasploit Express and Pro report types of "PWDump."
	#
	# This particular block scheme is temporary, since someone is 
	# bound to want to import gigantic lists, so we'll want a
	# stream parser eventually (just like the other non-nmap formats).
	#
	# The file format is:
	# # 1.2.3.4:23/tcp (telnet)
	# username password
	# user2 p\x01a\x02ss2
	# <BLANK> pass3
	# user3 <BLANK>
	# smbuser:sid:lmhash:nthash:::
	#
	# Note the leading hash for the host:port line. Note also all usernames
	# and passwords must be in 7-bit ASCII (character sequences of "\x01"
	# will be interpolated -- this includes spaces, which must be notated
	# as "\x20". Blank usernames or passwords should be <BLANK>.
	#
	def import_msf_pwdump(args={}, &block)
		data = args[:data]
		wspace = args[:wspace] || workspace
		bl = validate_ips(args[:blacklist]) ? args[:blacklist].split : []
		last_host = nil

		addr  = nil
		port  = nil
		proto = nil
		sname = nil
		ptype = nil
		active = false # Are there cases where imported creds are good? I just hate trusting the import right away.

		data.each_line do |line|
			case line
			when /^[\s]*#/ # Comment lines
				if line[/^#[\s]*([0-9.]+):([0-9]+)(\x2f(tcp|udp))?[\s]*(\x28([^\x29]*)\x29)?/]
					addr = $1
					port = $2
					proto = $4
					sname = $6
				end
			when /^[\s]*Warning:/
				next # Discard warning messages.
			when /^[\s]*([^\s:]+):[0-9]+:([A-Fa-f0-9]+:[A-Fa-f0-9]+):[^\s]*$/ # SMB Hash
				user = ([nil, "<BLANK>"].include?($1)) ? "" : $1
				pass = ([nil, "<BLANK>"].include?($2)) ? "" : $2
				ptype = "smb_hash"
			when /^[\s]*([^\s:]+):([0-9]+):NO PASSWORD\*+:NO PASSWORD\*+[^\s]*$/ # SMB Hash
				user = ([nil, "<BLANK>"].include?($1)) ? "" : $1
				pass = ""
				ptype = "smb_hash"
			when /^[\s]*([\x21-\x7f]+)[\s]+([\x21-\x7f]+)?/ # Must be a user pass
				user = ([nil, "<BLANK>"].include?($1)) ? "" : dehex($1)
				pass = ([nil, "<BLANK>"].include?($2)) ? "" : dehex($2)
				ptype = "password"
			else # Some unknown line not broken by a space.
				next
			end

			next unless [addr,port,user,pass].compact.size == 4
			next unless ipv4_validator(addr) # Skip Malformed addrs
			next unless port[/^[0-9]+$/] # Skip malformed ports
			if bl.include? addr
				next
			else
				yield(:address,addr) if block and addr != last_host
				last_host = addr
			end

			cred_info = {
				:host => addr,
				:port => port,
				:user => user,
				:pass => pass,
				:type => ptype,
				:workspace => wspace
			}
			cred_info[:proto] = proto if proto
			cred_info[:sname] = sname if sname
			cred_info[:active] = active

			report_auth_info(cred_info)
			user = pass = ptype = nil
		end
		
	end

	# If hex notation is present, turn them into a character.
	def dehex(str)
		hexen = str.scan(/\x5cx[0-9a-fA-F]{2}/)
		hexen.each { |h|
			str.gsub!(h,h[2,2].to_i(16).chr)
		}
		return str
	end


	#
	# Nexpose Simple XML
	#
	# XXX At some point we'll want to make this a stream parser for dealing
	# with large results files
	#
	def import_nexpose_simplexml_file(args={})
		filename = args[:filename]
		wspace = args[:wspace] || workspace

		data = ""
		::File.open(filename, 'rb') do |f|
			data = f.read(f.stat.size)
		end
		import_nexpose_simplexml(args.merge(:data => data))
	end

	# Import a Metasploit XML file.
	def import_msf_file(args={})
		filename = args[:filename]
		wspace = args[:wspace] || workspace

		data = ""
		::File.open(filename, 'rb') do |f|
			data = f.read(f.stat.size)
		end
		import_msf_xml(args.merge(:data => data))
	end

	# Import a Metasploit Express ZIP file. Note that this requires
	# a fair bit of filesystem manipulation, and is very much tied
	# up with the Metasploit Express ZIP file format export (for
	# obvious reasons). In the event directories exist, they will
	# be reused. If target files exist, they will be overwritten.
	#
	# XXX: Refactor so it's not quite as sanity-blasting.
	def import_msf_zip(args={}, &block)
		data = args[:data]
		wpsace = args[:wspace] || workspace
		bl = validate_ips(args[:blacklist]) ? args[:blacklist].split : []

		new_tmp = ::File.join(Dir::tmpdir,"msf","imp_#{Rex::Text::rand_text_alphanumeric(4)}",@import_filedata[:zip_basename])
		if ::File.exists? new_tmp
			unless (::File.directory?(new_tmp) && ::File.writable?(new_tmp))
				raise DBImportError.new("Could not extract zip file to #{new_tmp}")
			end
		else
			FileUtils.mkdir_p(new_tmp)
		end
		@import_filedata[:zip_tmp] = new_tmp

		@import_filedata[:zip_tmp_subdirs] = @import_filedata[:zip_entry_names].map {|x| ::File.split(x)}.map {|x| x[0]}.uniq.reject {|x| x == "."}

		@import_filedata[:zip_tmp_subdirs].each {|sub|
			tmp_subdirs = ::File.join(@import_filedata[:zip_tmp],sub)
			if File.exists? tmp_subdirs
				unless (::File.directory?(tmp_subdirs) && File.writable?(tmp_subdirs))
					raise DBImportError.new("Could not extract zip file to #{tmp_subdirs}")
				end
			else
				::FileUtils.mkdir(tmp_subdirs)
			end
		}


		data.entries.each do |e|
			target = ::File.join(@import_filedata[:zip_tmp],e.name)
			::File.unlink target if ::File.exists?(target) # Yep. Deleted.
			data.extract(e,target)
			if target =~ /^.*.xml$/
				target_data = ::File.open(target) {|f| f.read 1024}
				if import_filetype_detect(target_data) == :msf_xml
					@import_filedata[:zip_extracted_xml] = target
					break
				end
			end
		end

		# This will kick the newly-extracted XML file through
		# the import_file process all over again.
		if @import_filedata[:zip_extracted_xml]
			new_args = args.dup
			new_args[:filename] = @import_filedata[:zip_extracted_xml]
			new_args[:data] = nil
			new_args[:ifd] = @import_filedata.dup
			if block
				import_file(new_args, &block)
			else
				import_file(new_args)
			end
		end

		# Kick down to all the MSFX ZIP specific items
		if block
			import_msf_collateral(new_args, &block)
		else
			import_msf_collateral(new_args)
		end
	end

	# Imports loot, tasks, and reports from an MSF ZIP report.
	# XXX: This function is stupidly long. It needs to be refactored.
	def import_msf_collateral(args={}, &block)
		data = ::File.open(args[:filename], "rb") {|f| f.read(f.stat.size)}
		wspace = args[:wspace] || args['wspace'] || workspace
		bl = validate_ips(args[:blacklist]) ? args[:blacklist].split : []
		basedir = args[:basedir] || args['basedir'] || ::File.join(Msf::Config.install_root, "data", "msf")

		allow_yaml = false
		btag = nil

		doc = rexmlify(data)
		if doc.elements["MetasploitExpressV1"]
			m_ver = 1
			allow_yaml = true
			btag = "MetasploitExpressV1"
		elsif doc.elements["MetasploitExpressV2"]
			m_ver = 2
			allow_yaml = true
			btag = "MetasploitExpressV2"
		elsif doc.elements["MetasploitExpressV3"]
			m_ver = 3
			btag = "MetasploitExpressV3"
		elsif doc.elements["MetasploitExpressV4"]
			m_ver = 4
			btag = "MetasploitExpressV4"
		elsif doc.elements["MetasploitV4"]
			m_ver = 4
			btag = "MetasploitV4"			
		else
			m_ver = nil
		end
		unless m_ver and btag
			raise DBImportError.new("Unsupported Metasploit XML document format")
		end

		host_info = {}
		doc.elements.each("/#{btag}/hosts/host") do |host|
			host_info[host.elements["id"].text.to_s.strip] = nils_for_nulls(host.elements["address"].text.to_s.strip)
		end

		# Import Loot
		doc.elements.each("/#{btag}/loots/loot") do |loot|
			next if bl.include? host_info[loot.elements["host-id"].text.to_s.strip]
			loot_info = {}
			loot_info[:host] = host_info[loot.elements["host-id"].text.to_s.strip]
			loot_info[:workspace] = args[:wspace]
			loot_info[:ctype] = nils_for_nulls(loot.elements["content-type"].text.to_s.strip)
			loot_info[:info] = nils_for_nulls(unserialize_object(loot.elements["info"], allow_yaml))
			loot_info[:ltype] = nils_for_nulls(loot.elements["ltype"].text.to_s.strip)
			loot_info[:name] = nils_for_nulls(loot.elements["name"].text.to_s.strip)
			loot_info[:created_at] = nils_for_nulls(loot.elements["created-at"].text.to_s.strip)
			loot_info[:updated_at] = nils_for_nulls(loot.elements["updated-at"].text.to_s.strip)
			loot_info[:name] = nils_for_nulls(loot.elements["name"].text.to_s.strip)
			loot_info[:orig_path] = nils_for_nulls(loot.elements["path"].text.to_s.strip)
			tmp = args[:ifd][:zip_tmp]
			loot_info[:orig_path].gsub!(/^\./,tmp) if loot_info[:orig_path]
			if !loot.elements["service-id"].text.to_s.strip.empty?
				unless loot.elements["service-id"].text.to_s.strip == "NULL"
					loot_info[:service] = loot.elements["service-id"].text.to_s.strip
				end
			end

			# Only report loot if we actually have it.
			# TODO: Copypasta. Seperate this out.
			if ::File.exists? loot_info[:orig_path]
				loot_dir = ::File.join(basedir,"loot")
				loot_file = ::File.split(loot_info[:orig_path]).last
				if ::File.exists? loot_dir
					unless (::File.directory?(loot_dir) && ::File.writable?(loot_dir))
						raise DBImportError.new("Could not move files to #{loot_dir}")
					end
				else
					::FileUtils.mkdir_p(loot_dir)
				end
				new_loot = ::File.join(loot_dir,loot_file)
				loot_info[:path] = new_loot
				if ::File.exists?(new_loot)
					::File.unlink new_loot # Delete it, and don't report it.
				else
					report_loot(loot_info) # It's new, so report it.
				end
				::FileUtils.copy(loot_info[:orig_path], new_loot)
				yield(:msf_loot, new_loot) if block
			end
		end

		# Import Tasks
		doc.elements.each("/#{btag}/tasks/task") do |task|
			task_info = {}
			task_info[:workspace] = args[:wspace]
			# Should user be imported (original) or declared (the importing user)?
			task_info[:user] = nils_for_nulls(task.elements["created-by"].text.to_s.strip)
			task_info[:desc] = nils_for_nulls(task.elements["description"].text.to_s.strip)
			task_info[:info] = nils_for_nulls(unserialize_object(task.elements["info"], allow_yaml))
			task_info[:mod] = nils_for_nulls(task.elements["module"].text.to_s.strip)
			task_info[:options] = nils_for_nulls(task.elements["options"].text.to_s.strip)
			task_info[:prog] = nils_for_nulls(task.elements["progress"].text.to_s.strip).to_i
			task_info[:created_at] = nils_for_nulls(task.elements["created-at"].text.to_s.strip)
			task_info[:updated_at] = nils_for_nulls(task.elements["updated-at"].text.to_s.strip)
			if !task.elements["completed-at"].text.to_s.empty?
				task_info[:completed_at] = nils_for_nulls(task.elements["completed-at"].text.to_s.strip)
			end
			if !task.elements["error"].text.to_s.empty?
				task_info[:error] = nils_for_nulls(task.elements["error"].text.to_s.strip)
			end
			if !task.elements["result"].text.to_s.empty?
				task_info[:result] = nils_for_nulls(task.elements["result"].text.to_s.strip)
			end
			task_info[:orig_path] = nils_for_nulls(task.elements["path"].text.to_s.strip)
			tmp = args[:ifd][:zip_tmp]
			task_info[:orig_path].gsub!(/^\./,tmp) if task_info[:orig_path]

			# Only report a task if we actually have it.
			# TODO: Copypasta. Seperate this out.
			if ::File.exists? task_info[:orig_path]
				tasks_dir = ::File.join(basedir,"tasks")
				task_file = ::File.split(task_info[:orig_path]).last
				if ::File.exists? tasks_dir
					unless (::File.directory?(tasks_dir) && ::File.writable?(tasks_dir))
						raise DBImportError.new("Could not move files to #{tasks_dir}")
					end
				else
					::FileUtils.mkdir_p(tasks_dir)
				end
				new_task = ::File.join(tasks_dir,task_file)
				task_info[:path] = new_task
				if ::File.exists?(new_task)
					::File.unlink new_task # Delete it, and don't report it.
				else
					report_task(task_info) # It's new, so report it.
				end
				::FileUtils.copy(task_info[:orig_path], new_task)
				yield(:msf_task, new_task) if block
			end
		end

		# Import Reports
		doc.elements.each("/#{btag}/reports/report") do |report|
			report_info = {}
			report_info[:workspace] = args[:wspace]
			# Should user be imported (original) or declared (the importing user)?
			report_info[:user] = nils_for_nulls(report.elements["created-by"].text.to_s.strip)
			report_info[:options] = nils_for_nulls(report.elements["options"].text.to_s.strip)
			report_info[:rtype] = nils_for_nulls(report.elements["rtype"].text.to_s.strip)
			report_info[:created_at] = nils_for_nulls(report.elements["created-at"].text.to_s.strip)
			report_info[:updated_at] = nils_for_nulls(report.elements["updated-at"].text.to_s.strip)

			report_info[:orig_path] = nils_for_nulls(report.elements["path"].text.to_s.strip)
			tmp = args[:ifd][:zip_tmp]
			report_info[:orig_path].gsub!(/^\./,tmp) if report_info[:orig_path]

			# Only report a report if we actually have it.
			# TODO: Copypasta. Seperate this out.
			if ::File.exists? report_info[:orig_path]
				reports_dir = ::File.join(basedir,"reports")
				report_file = ::File.split(report_info[:orig_path]).last
				if ::File.exists? reports_dir
					unless (::File.directory?(reports_dir) && ::File.writable?(reports_dir))
						raise DBImportError.new("Could not move files to #{reports_dir}")
					end
				else
					::FileUtils.mkdir_p(reports_dir)
				end
				new_report = ::File.join(reports_dir,report_file)
				report_info[:path] = new_report
				if ::File.exists?(new_report)
					::File.unlink new_report
				else
					report_report(report_info)
				end
				::FileUtils.copy(report_info[:orig_path], new_report)
				yield(:msf_report, new_report) if block
			end
		end

	end

	# For each host, step through services, notes, and vulns, and import
	# them.
	# TODO: loot, tasks, and reports
	def import_msf_xml(args={}, &block)
		data = args[:data]
		wspace = args[:wspace] || workspace
		bl = validate_ips(args[:blacklist]) ? args[:blacklist].split : []

		allow_yaml = false
		btag       = nil
		
		doc = rexmlify(data)
		if doc.elements["MetasploitExpressV1"]
			m_ver = 1
			allow_yaml = true
			btag = "MetasploitExpressV1"
		elsif doc.elements["MetasploitExpressV2"]
			m_ver = 2
			allow_yaml = true
			btag = "MetasploitExpressV2"			
		elsif doc.elements["MetasploitExpressV3"]
			m_ver = 3
			btag = "MetasploitExpressV3"			
		elsif doc.elements["MetasploitExpressV4"]
			m_ver = 4			
			btag = "MetasploitExpressV4"
		elsif doc.elements["MetasploitV4"]
			m_ver = 4			
			btag = "MetasploitV4"						
		else
			m_ver = nil
		end
		unless m_ver and btag
			raise DBImportError.new("Unsupported Metasploit XML document format")
		end

		doc.elements.each("/#{btag}/hosts/host") do |host|
			host_data = {}
			host_data[:workspace] = wspace
			host_data[:host] = nils_for_nulls(host.elements["address"].text.to_s.strip)
			if bl.include? host_data[:host]
				next
			else
				yield(:address,host_data[:host]) if block
			end
			host_data[:host_mac] = nils_for_nulls(host.elements["mac"].text.to_s.strip)
			if host.elements["comm"].text
				host_data[:comm] = nils_for_nulls(host.elements["comm"].text.to_s.strip)
			end
			%W{created-at updated-at name state os-flavor os-lang os-name os-sp purpose}.each { |datum|
				if host.elements[datum].text
					host_data[datum.gsub('-','_')] = nils_for_nulls(host.elements[datum].text.to_s.strip)
				end
			}
			host_address = host_data[:host].dup # Preserve after report_host() deletes
			report_host(host_data)
			host.elements.each('services/service') do |service|
				service_data = {}
				service_data[:workspace] = wspace
				service_data[:host] = host_address
				service_data[:port] = nils_for_nulls(service.elements["port"].text.to_s.strip).to_i
				service_data[:proto] = nils_for_nulls(service.elements["proto"].text.to_s.strip)
				%W{created-at updated-at name state info}.each { |datum|
					if service.elements[datum].text
						if datum == "info"
							service_data["info"] = nils_for_nulls(unserialize_object(service.elements[datum], false))
						else
							service_data[datum.gsub("-","_")] = nils_for_nulls(service.elements[datum].text.to_s.strip)
						end
					end
				}
				report_service(service_data)
			end
			host.elements.each('notes/note') do |note|
				note_data = {}
				note_data[:workspace] = wspace
				note_data[:host] = host_address
				note_data[:type] = nils_for_nulls(note.elements["ntype"].text.to_s.strip)
				note_data[:data] = nils_for_nulls(unserialize_object(note.elements["data"], allow_yaml))

				if note.elements["critical"].text
					note_data[:critical] = true unless note.elements["critical"].text.to_s.strip == "NULL"
				end
				if note.elements["seen"].text
					note_data[:seen] = true unless note.elements["critical"].text.to_s.strip == "NULL"
				end
				%W{created-at updated-at}.each { |datum|
					if note.elements[datum].text
						note_data[datum.gsub("-","_")] = nils_for_nulls(note.elements[datum].text.to_s.strip)
					end
				}
				report_note(note_data)
			end
			host.elements.each('tags/tag') do |tag|
				tag_data = {}
				tag_data[:addr] = host_address
				tag_data[:wspace] = wspace
				tag_data[:name] = tag.elements["name"].text.to_s.strip
				tag_data[:desc] = tag.elements["desc"].text.to_s.strip
				if tag.elements["report-summary"].text
					tag_data[:summary] = tag.elements["report-summary"].text.to_s.strip
				end
				if tag.elements["report-detail"].text
					tag_data[:detail] = tag.elements["report-detail"].text.to_s.strip
				end
				if tag.elements["critical"].text
					tag_data[:crit] = true unless tag.elements["critical"].text.to_s.strip == "NULL"
				end
				report_host_tag(tag_data)
			end
			host.elements.each('vulns/vuln') do |vuln|
				vuln_data = {}
				vuln_data[:workspace] = wspace
				vuln_data[:host] = host_address
				vuln_data[:info] = nils_for_nulls(unserialize_object(vuln.elements["info"], allow_yaml))
				vuln_data[:name] = nils_for_nulls(vuln.elements["name"].text.to_s.strip)
				%W{created-at updated-at}.each { |datum|
					if vuln.elements[datum].text
						vuln_data[datum.gsub("-","_")] = nils_for_nulls(vuln.elements[datum].text.to_s.strip)
					end
				}
				report_vuln(vuln_data)
			end
			host.elements.each('creds/cred') do |cred|
				cred_data = {}
				cred_data[:workspace] = wspace
				cred_data[:host] = host_address
				%W{port ptype sname proto proof active user pass}.each {|datum|
					if cred.elements[datum].respond_to? :text
						cred_data[datum.intern] = nils_for_nulls(cred.elements[datum].text.to_s.strip)
					end
				}
				%W{created-at updated-at}.each { |datum|
					if cred.elements[datum].respond_to? :text
						cred_data[datum.gsub("-","_")] = nils_for_nulls(cred.elements[datum].text.to_s.strip)
					end
				}
				if cred_data[:pass] == "<masked>"
					cred_data[:pass] = ""
					cred_data[:active] = false
				elsif cred_data[:pass] == "*BLANK PASSWORD*"
					cred_data[:pass] = ""
				end
				report_cred(cred_data.merge(:wait => true))
			end
		end
		
		# Import web sites
		doc.elements.each("/#{btag}/web_sites/web_site") do |web|
			info = {}
			info[:workspace] = wspace
			
			%W{host port vhost ssl comments}.each do |datum|
				if web.elements[datum].respond_to? :text
					info[datum.intern] = nils_for_nulls(web.elements[datum].text.to_s.strip)
				end					
			end
								
			info[:options]   = nils_for_nulls(unserialize_object(web.elements["options"], allow_yaml)) if web.elements["options"].respond_to?(:text)
			info[:ssl]       = (info[:ssl] and info[:ssl].to_s.strip.downcase == "true") ? true : false
									
			%W{created-at updated-at}.each { |datum|
				if web.elements[datum].text
					info[datum.gsub("-","_")] = nils_for_nulls(web.elements[datum].text.to_s.strip)
				end
			}
			
			report_web_site(info)
			yield(:web_site, "#{info[:host]}:#{info[:port]} (#{info[:vhost]})") if block
		end
		
		%W{page form vuln}.each do |wtype|
			doc.elements.each("/#{btag}/web_#{wtype}s/web_#{wtype}") do |web|
				info = {}
				info[:workspace] = wspace
				info[:host]      = nils_for_nulls(web.elements["host"].text.to_s.strip)  if web.elements["host"].respond_to?(:text)
				info[:port]      = nils_for_nulls(web.elements["port"].text.to_s.strip)  if web.elements["port"].respond_to?(:text)
				info[:ssl]       = nils_for_nulls(web.elements["ssl"].text.to_s.strip)   if web.elements["ssl"].respond_to?(:text)
				info[:vhost]     = nils_for_nulls(web.elements["vhost"].text.to_s.strip) if web.elements["vhost"].respond_to?(:text)
				
				info[:ssl] = (info[:ssl] and info[:ssl].to_s.strip.downcase == "true") ? true : false
				
				case wtype
				when "page"
					%W{path code body query cookie auth ctype mtime location}.each do |datum|
						if web.elements[datum].respond_to? :text
							info[datum.intern] = nils_for_nulls(web.elements[datum].text.to_s.strip)
						end					
					end
					info[:headers] = nils_for_nulls(unserialize_object(web.elements["headers"], allow_yaml))
				when "form"
					%W{path query method}.each do |datum|
						if web.elements[datum].respond_to? :text
							info[datum.intern] = nils_for_nulls(web.elements[datum].text.to_s.strip)
						end					
					end
					info[:params] = nils_for_nulls(unserialize_object(web.elements["params"], allow_yaml))				
				when "vuln"
					%W{path query method pname proof risk name blame description category confidence}.each do |datum|
						if web.elements[datum].respond_to? :text
							info[datum.intern] = nils_for_nulls(web.elements[datum].text.to_s.strip)
						end					
					end
					info[:params] = nils_for_nulls(unserialize_object(web.elements["params"], allow_yaml))		
					info[:risk]   = info[:risk].to_i			
					info[:confidence] = info[:confidence].to_i							
				end
									
				%W{created-at updated-at}.each { |datum|
					if web.elements[datum].text
						info[datum.gsub("-","_")] = nils_for_nulls(web.elements[datum].text.to_s.strip)
					end
				}
				self.send("report_web_#{wtype}", info)
				
				yield("web_#{wtype}".intern, info[:path]) if block
			end
		end
	end

	# Convert the string "NULL" to actual nil
	def nils_for_nulls(str)
		str == "NULL" ? nil : str
	end

	def import_nexpose_simplexml(args={}, &block)
		data = args[:data]
		wspace = args[:wspace] || workspace
		bl = validate_ips(args[:blacklist]) ? args[:blacklist].split : []

		doc = rexmlify(data)
		doc.elements.each('/NeXposeSimpleXML/devices/device') do |dev|
			addr = dev.attributes['address'].to_s
			if bl.include? addr
				next
			else
				yield(:address,addr) if block
			end

			fprint = {}

			dev.elements.each('fingerprint/description') do |str|
				fprint[:desc] = str.text.to_s.strip
			end
			dev.elements.each('fingerprint/vendor') do |str|
				fprint[:vendor] = str.text.to_s.strip
			end
			dev.elements.each('fingerprint/family') do |str|
				fprint[:family] = str.text.to_s.strip
			end
			dev.elements.each('fingerprint/product') do |str|
				fprint[:product] = str.text.to_s.strip
			end
			dev.elements.each('fingerprint/version') do |str|
				fprint[:version] = str.text.to_s.strip
			end
			dev.elements.each('fingerprint/architecture') do |str|
				fprint[:arch] = str.text.to_s.upcase.strip
			end

			conf = {
				:workspace => wspace,
				:host      => addr,
				:state     => Msf::HostState::Alive
			}

			report_host(conf)

			report_note(
				:workspace => wspace,
				:host      => addr,
				:type      => 'host.os.nexpose_fingerprint',
				:data      => fprint
			)

			# Load vulnerabilities not associated with a service
			dev.elements.each('vulnerabilities/vulnerability') do |vuln|
				vid  = vuln.attributes['id'].to_s.downcase
				refs = process_nexpose_data_sxml_refs(vuln)
				next if not refs
				report_vuln(
					:workspace => wspace,
					:host      => addr,
					:name      => 'NEXPOSE-' + vid,
					:info      => vid,
					:refs      => refs)
			end

			# Load the services
			dev.elements.each('services/service') do |svc|
				sname = svc.attributes['name'].to_s
				sprot = svc.attributes['protocol'].to_s.downcase
				sport = svc.attributes['port'].to_s.to_i
				next if sport == 0

				name = sname.split('(')[0].strip
				info = ''

				svc.elements.each('fingerprint/description') do |str|
					info = str.text.to_s.strip
				end

				if(sname.downcase != '<unknown>')
					report_service(:workspace => wspace, :host => addr, :proto => sprot, :port => sport, :name => name, :info => info)
				else
					report_service(:workspace => wspace, :host => addr, :proto => sprot, :port => sport, :info => info)
				end

				# Load vulnerabilities associated with this service
				svc.elements.each('vulnerabilities/vulnerability') do |vuln|
					vid  = vuln.attributes['id'].to_s.downcase
					refs = process_nexpose_data_sxml_refs(vuln)
					next if not refs
					report_vuln(
						:workspace => wspace,
						:host => addr,
						:port => sport,
						:proto => sprot,
						:name => 'NEXPOSE-' + vid,
						:info => vid,
						:refs => refs)
				end
			end
		end
	end


	#
	# Nexpose Raw XML
	#
	def import_nexpose_rawxml_file(args={})
		filename = args[:filename]
		wspace = args[:wspace] || workspace

		data = ""
		::File.open(filename, 'rb') do |f|
			data = f.read(f.stat.size)
		end
		import_nexpose_rawxml(args.merge(:data => data))
	end

	def import_nexpose_rawxml(args={}, &block)
		data = args[:data]
		wspace = args[:wspace] || workspace
		bl = validate_ips(args[:blacklist]) ? args[:blacklist].split : []

		# Use a stream parser instead of a tree parser so we can deal with
		# huge results files without running out of memory.
		parser = Rex::Parser::NexposeXMLStreamParser.new

		# Since all the Refs have to be in the database before we can use them
		# in a Vuln, we store all the hosts until we finish parsing and only
		# then put everything in the database.  This is memory-intensive for
		# large files, but should be much less so than a tree parser.
		#
		# This method is also considerably faster than parsing through the tree
		# looking for references every time we hit a vuln.
		hosts = []
		vulns = []

		# The callback merely populates our in-memory table of hosts and vulns
		parser.callback = Proc.new { |type, value|
			case type
			when :host
				hosts.push(value)
			when :vuln
				value["id"] = value["id"].downcase if value["id"]
				vulns.push(value)
			end
		}

		REXML::Document.parse_stream(data, parser)

		vuln_refs = nexpose_refs_to_hash(vulns)
		hosts.each do |host|
			if bl.include? host["addr"]
				next
			else
				yield(:address,host["addr"]) if block
			end
			nexpose_host(host, vuln_refs, wspace)
		end
	end

	#
	# Takes an array of vuln hashes, as returned by the NeXpose rawxml stream
	# parser, like:
	#   [
	#		{"id"=>"winreg-notes-protocol-handler", severity="8", "refs"=>[{"source"=>"BID", "value"=>"10600"}, ...]}
	#		{"id"=>"windows-zotob-c", severity="8", "refs"=>[{"source"=>"BID", "value"=>"14513"}, ...]}
	#	]
	# and transforms it into a hash of vuln references keyed on vuln id, like:
	#	{ "windows-zotob-c" => [{"source"=>"BID", "value"=>"14513"}, ...] }
	#
	# This method ignores all attributes other than the vuln's NeXpose ID and
	# references (including title, severity, et cetera).
	#
	def nexpose_refs_to_hash(vulns)
		refs = {}
		vulns.each do |vuln|
			vuln["refs"].each do |ref|
				refs[vuln['id']] ||= []
				if ref['source'] == 'BID'
					refs[vuln['id']].push('BID-' + ref["value"])
				elsif ref['source'] == 'CVE'
					# value is CVE-$ID
					refs[vuln['id']].push(ref["value"])
				elsif ref['source'] == 'MS'
					refs[vuln['id']].push('MSB-' + ref["value"])
				elsif ref['source'] == 'URL'
					refs[vuln['id']].push('URL-' + ref["value"])
				#else
				#	$stdout.puts("Unknown source: #{ref["source"]}")
				end
			end
		end
		refs
	end

	def nexpose_host(h, vuln_refs, wspace)
		data = {:workspace => wspace}
		if h["addr"]
			addr = h["addr"]
		else
			# Can't report it if it doesn't have an IP
			return
		end
		data[:host] = addr
		if (h["hardware-address"])
			# Put colons between each octet of the MAC address
			data[:mac] = h["hardware-address"].gsub(':', '').scan(/../).join(':')
		end
		data[:state] = (h["status"] == "alive") ? Msf::HostState::Alive : Msf::HostState::Dead

		# Since we only have one name field per host in the database, just
		# take the first one.
		if (h["names"] and h["names"].first)
			data[:name] = h["names"].first
		end

		if (data[:state] != Msf::HostState::Dead)
			report_host(data)
		end

		if h["os_family"]
			note = {
				:workspace => wspace,
				:host => addr,
				:type => 'host.os.nexpose_fingerprint',
				:data => {
					:family    => h["os_family"],
					:certainty => h["os_certainty"]
				}
			}
			note[:data][:vendor]  = h["os_vendor"]  if h["os_vendor"]
			note[:data][:product] = h["os_product"] if h["os_product"]
			note[:data][:arch]    = h["arch"]       if h["arch"]

			report_note(note)
		end

		h["endpoints"].each { |p|
			extra = ""
			extra << p["product"] + " " if p["product"]
			extra << p["version"] + " " if p["version"]

			# Skip port-0 endpoints
			next if p["port"].to_i == 0

			# XXX This should probably be handled in a more standard way
			# extra << "(" + p["certainty"] + " certainty) " if p["certainty"]

			data = {}
			data[:workspace] = wspace
			data[:proto] = p["protocol"].downcase
			data[:port]  = p["port"].to_i
			data[:state] = p["status"]
			data[:host]  = addr
			data[:info]  = extra if not extra.empty?
			if p["name"] != "<unknown>"
				data[:name] = p["name"]
			end
			report_service(data)
		}

		h["vulns"].each_pair { |k,v|
			next if v["status"] !~ /^vulnerable/
			data = {}
			data[:workspace] = wspace
			data[:host] = addr
			data[:proto] = v["protocol"].downcase if v["protocol"]
			data[:port] = v["port"].to_i if v["port"]
			data[:name] = "NEXPOSE-" + v["id"]
			data[:refs] = vuln_refs[v["id"].to_s.downcase]
			report_vuln(data)
		}
	end


	#
	# Retina XML
	#

	# Process a Retina XML file
	def import_retina_xml_file(args={})
		filename = args[:filename]
		wspace = args[:wspace] || workspace

		data = ""
		::File.open(filename, 'rb') do |f|
			data = f.read(f.stat.size)
		end
		import_retina_xml(args.merge(:data => data))
	end

	# Process Retina XML
	def import_retina_xml(args={}, &block)
		data = args[:data]
		wspace = args[:wspace] || workspace
		bl = validate_ips(args[:blacklist]) ? args[:blacklist].split : []
	
		parser = Rex::Parser::RetinaXMLStreamParser.new
		parser.on_found_host = Proc.new do |host|
			data = {:workspace => wspace}
			addr = host['address']
			next if not addr
			
			next if bl.include? addr
			data[:host] = addr
			
			if host['mac']
				data[:mac] = host['mac']
			end
			
			data[:state] = Msf::HostState::Alive

			if host['hostname']
				data[:name] = host['hostname']
			end

			if host['netbios']
				data[:name] = host['netbios']
			end
			
			yield(:address, data[:host]) if block
			
			# Import Host
			report_host(data)
			report_import_note(wspace, addr)
			
			# Import OS fingerprint
			if host["os"]
				note = {
					:workspace => wspace,
					:host => addr,
					:type => 'host.os.retina_fingerprint',
					:data => {
						:os => host["os"]
					}
				}
				report_note(note)
			end
			
			# Import vulnerabilities
			host['vulns'].each do |vuln|
				refs = vuln['refs'].map{|v| v.join("-")}
				refs << "RETINA-#{vuln['rthid']}" if vuln['rthid']

				vuln_info = {
					:workspace => wspace,
					:host => addr,
					:name => vuln['name'],
					:info => vuln['description'],
					:refs => refs
				}
				
				report_vuln(vuln_info)
			end
		end

		REXML::Document.parse_stream(data, parser)
	end

	#
	# NetSparker XML
	#

	# Process a NetSparker XML file
	def import_netsparker_xml_file(args={})
		filename = args[:filename]
		wspace = args[:wspace] || workspace

		data = ""
		::File.open(filename, 'rb') do |f|
			data = f.read(f.stat.size)
		end
		import_netsparker_xml(args.merge(:data => data))
	end

	# Process NetSparker XML
	def import_netsparker_xml(args={}, &block)
		data = args[:data]
		wspace = args[:wspace] || workspace
		bl = validate_ips(args[:blacklist]) ? args[:blacklist].split : []
		addr = nil
		parser = Rex::Parser::NetSparkerXMLStreamParser.new
		parser.on_found_vuln = Proc.new do |vuln|
			data = {:workspace => wspace}

			# Parse the URL
			url  = vuln['url']
			return if not url

			# Crack the URL into a URI			
			uri = URI(url) rescue nil
			return if not uri
			
			# Resolve the host and cache the IP
			if not addr
				baddr = Rex::Socket.addr_aton(uri.host) rescue nil
				if baddr
					addr = Rex::Socket.addr_ntoa(baddr)
					yield(:address, data[:host]) if block
				end
			end
			
			# Bail early if we have no IP address
			if not addr
				raise Interrupt, "Not a valid IP address"
			end
			
			if bl.include?(addr)
				raise Interrupt, "IP address is on the blacklist"
			end

			data[:host]  = addr
			data[:vhost] = uri.host
			data[:port]  = uri.port
			data[:ssl]   = (uri.scheme == "ssl")
		
			body = nil
			# First report a web page
			if vuln['response']
				headers = {}
				code    = 200
				head,body = vuln['response'].to_s.split(/\r?\n\r?\n/, 2)
				if body
				
					if head =~ /^HTTP\d+\.\d+\s+(\d+)\s*/
						code = $1.to_i
					end
				
					headers = {}
					head.split(/\r?\n/).each do |line|
						hname,hval = line.strip.split(/\s*:\s*/, 2)
						next if hval.to_s.strip.empty?
						headers[hname.downcase] ||= []
						headers[hname.downcase] << hval
					end
					
					info = { 
						:path     => uri.path,
						:query    => uri.query,
						:code     => code,
						:body     => body,
						:headers  => headers
					}
					info.merge!(data)
					
					if headers['content-type']
						info[:ctype] = headers['content-type'][0]
					end
		
					if headers['set-cookie']
						info[:cookie] = headers['set-cookie'].join("\n")
					end

					if headers['authorization']
						info[:auth] = headers['authorization'].join("\n")
					end

					if headers['location']
						info[:location] = headers['location'][0]
					end
		
					if headers['last-modified']
						info[:mtime] = headers['last-modified'][0]
					end
									
					# Report the web page to the database
					report_web_page(info)
					
					yield(:web_page, url) if block
				end
			end # End web_page reporting
			
			
			details = netsparker_vulnerability_map(vuln)
			
			method = netsparker_method_map(vuln)
			pname  = netsparker_pname_map(vuln)
			params = netsparker_params_map(vuln)
			
			proof  = ''
			
			if vuln['info'] and vuln['info'].length > 0
				proof << vuln['info'].map{|x| "#{x[0]}: #{x[1]}\n" }.join + "\n"
			end
			
			if proof.empty?
				if body
					proof << body + "\n"
				else
					proof << vuln['response'].to_s + "\n"
				end
			end
			
			if params.empty? and pname
				params = [[pname, vuln['vparam_name'].to_s]]
			end

			info = {
				:path     => uri.path,
				:query    => uri.query,
				:method   => method,
				:params   => params,
				:pname    => pname.to_s,
				:proof    => proof,
				:risk     => details[:risk],
				:name     => details[:name],
				:blame    => details[:blame],
				:category => details[:category],
				:description => details[:description],
				:confidence  => details[:confidence],				
			}
			info.merge!(data)
			
			next if vuln['type'].to_s.empty?
			
			report_web_vuln(info)
			yield(:web_vuln, url) if block			
		end

		# We throw interrupts in our parser when the job is hopeless
		begin
			REXML::Document.parse_stream(data, parser)
		rescue ::Interrupt => e
			wlog("The netsparker_xml_import() job was interrupted: #{e}")
		end
	end
	
	def netsparker_method_map(vuln)
		case vuln['vparam_type']
		when "FullQueryString"
			"GET"
		when "Querystring"
			"GET"
		when "Post"
			"POST"
		when "RawUrlInjection"
			"GET"
		else
			"GET"
		end
	end
	
	def netsparker_pname_map(vuln)
		case vuln['vparam_name']
		when "URI-BASED", "Query Based"
			"PATH"
		else
			vuln['vparam_name']
		end
	end
	
	def netsparker_params_map(vuln)
		[]
	end
	
	def netsparker_vulnerability_map(vuln)
		res = {
			:risk => 1,
			:name  => 'Information Disclosure',
			:blame => 'System Administrator',
			:category => 'info',
			:description => "This is an information leak",
			:confidence => 100
		}
		
		# Risk is a value from 1-5 indicating the severity of the issue
		#	Examples: 1, 4, 5
		
		# Name is a descriptive name for this vulnerability.
		#	Examples: XSS, ReflectiveXSS, PersistentXSS
		
		# Blame indicates who is at fault for the vulnerability
		#	Examples: App Developer, Server Developer, System Administrator

		# Category indicates the general class of vulnerability
		#	Examples: info, xss, sql, rfi, lfi, cmd
		
		# Description is a textual summary of the vulnerability
		#	Examples: "A reflective cross-site scripting attack"
		#             "The web server leaks the internal IP address"
		#             "The cookie is not set to HTTP-only"
		
		#
		# Confidence is a value from 1 to 100 indicating how confident the 
		# software is that the results are valid.
		#	Examples: 100, 90, 75, 15, 10, 0

		case vuln['type'].to_s
		when "ApacheDirectoryListing"
			res = {
				:risk => 1,
				:name  => 'Directory Listing',
				:blame => 'System Administrator',
				:category => 'info',
				:description => "",
				:confidence => 100
			}
		when "ApacheMultiViewsEnabled"
			res = {
				:risk => 1,
				:name  => 'Apache MultiViews Enabled',
				:blame => 'System Administrator',
				:category => 'info',
				:description => "",
				:confidence => 100
			}
		when "ApacheVersion"
			res = {
				:risk => 1,
				:name  => 'Web Server Version',
				:blame => 'System Administrator',
				:category => 'info',
				:description => "",
				:confidence => 100
			}
		when "PHPVersion"
			res = {
				:risk => 1,
				:name  => 'PHP Module Version',
				:blame => 'System Administrator',
				:category => 'info',
				:description => "",
				:confidence => 100
			}
		when "AutoCompleteEnabled"
			res = {
				:risk => 1,
				:name  => 'Form AutoComplete Enabled',
				:blame => 'App Developer',
				:category => 'info',
				:description => "",
				:confidence => 100
			}
		when "CookieNotMarkedAsHttpOnly"
			res = {
				:risk => 1,
				:name  => 'Cookie Not HttpOnly',
				:blame => 'App Developer',
				:category => 'info',
				:description => "",
				:confidence => 100
			}
		when "EmailDisclosure"
			res = {
				:risk => 1,
				:name  => 'Email Address Disclosure',
				:blame => 'App Developer',
				:category => 'info',
				:description => "",
				:confidence => 100
			}
		when "ForbiddenResource"
			res = {
				:risk => 1,
				:name  => 'Forbidden Resource',
				:blame => 'App Developer',
				:category => 'info',
				:description => "",
				:confidence => 100
			}
		when "FileUploadFound"
			res = {
				:risk => 1,
				:name  => 'File Upload Form',
				:blame => 'App Developer',
				:category => 'info',
				:description => "",
				:confidence => 100
			}
		when "PasswordOverHTTP"
			res = {
				:risk => 2,
				:name  => 'Password Over HTTP',
				:blame => 'App Developer',
				:category => 'info',
				:description => "",
				:confidence => 100
			}
		when "MySQL5Identified"
			res = {
				:risk => 1,
				:name  => 'MySQL 5 Identified',
				:blame => 'App Developer',
				:category => 'info',
				:description => "",
				:confidence => 100
			}
		when "PossibleInternalWindowsPathLeakage"
			res = {
				:risk => 1,
				:name  => 'Path Leakage - Windows',
				:blame => 'App Developer',
				:category => 'info',
				:description => "",
				:confidence => 100
			}
		when "PossibleInternalUnixPathLeakage"
			res = {
				:risk => 1,
				:name  => 'Path Leakage - Unix',
				:blame => 'App Developer',
				:category => 'info',
				:description => "",
				:confidence => 100
			}			
		when "PossibleXSS", "LowPossibilityPermanentXSS", "XSS", "PermanentXSS"																																
			conf = 100
			conf = 25  if vuln['type'].to_s == "LowPossibilityPermanentXSS"
			conf = 50  if vuln['type'].to_s == "PossibleXSS"
			res = {
				:risk => 3,
				:name  => 'Cross-Site Scripting',
				:blame => 'App Developer',
				:category => 'xss',
				:description => "",
				:confidence => conf
			}						
		
		when "ConfirmedBlindSQLInjection", "ConfirmedSQLInjection", "HighlyPossibleSqlInjection", "DatabaseErrorMessages"
			conf = 100
			conf = 90  if vuln['type'].to_s == "HighlyPossibleSqlInjection"
			conf = 25  if vuln['type'].to_s == "DatabaseErrorMessages"
			res = {
				:risk => 5,
				:name  => 'SQL Injection',
				:blame => 'App Developer',
				:category => 'sql',
				:description => "",
				:confidence => conf
			}		
		else
		conf = 100
		res = {
			:risk => 1,
			:name  => vuln['type'].to_s,
			:blame => 'App Developer',
			:category => 'info',
			:description => "",
			:confidence => conf
		}			
		end
		
		res
	end

	
	#
	# Import Nmap's -oX xml output
	#
	def import_nmap_xml_file(args={})
		filename = args[:filename]
		wspace = args[:wspace] || workspace

		data = ""
		::File.open(filename, 'rb') do |f|
			data = f.read(f.stat.size)
		end
		import_nmap_xml(args.merge(:data => data))
	end

	# Too many functions in one def! Refactor this.
	def import_nmap_xml(args={}, &block)
		data = args[:data]
		wspace = args[:wspace] || workspace
		bl = validate_ips(args[:blacklist]) ? args[:blacklist].split : []
		fix_services = args[:fix_services]

		# Use a stream parser instead of a tree parser so we can deal with
		# huge results files without running out of memory.
		parser = Rex::Parser::NmapXMLStreamParser.new

		# Whenever the parser pulls a host out of the nmap results, store
		# it, along with any associated services, in the database.
		parser.on_found_host = Proc.new { |h|
			data = {:workspace => wspace}
			if (h["addrs"].has_key?("ipv4"))
				addr = h["addrs"]["ipv4"]
			elsif (h["addrs"].has_key?("ipv6"))
				addr = h["addrs"]["ipv6"]
			else
				# Can't report it if it doesn't have an IP
				raise RuntimeError, "At least one IPv4 or IPv6 address is required"
			end
			next if bl.include? addr
			data[:host] = addr
			if (h["addrs"].has_key?("mac"))
				data[:mac] = h["addrs"]["mac"]
			end
			data[:state] = (h["status"] == "up") ? Msf::HostState::Alive : Msf::HostState::Dead

			if ( h["reverse_dns"] )
				data[:name] = h["reverse_dns"]
			end

			# Only report alive hosts with ports to speak of.
			if(data[:state] != Msf::HostState::Dead)
				if h["ports"].size > 0
					if fix_services
						port_states = h["ports"].map {|p| p["state"]}.reject {|p| p == "filtered"}
						next if port_states.compact.empty?
					end
					yield(:address,data[:host]) if block
					report_host(data)
					report_import_note(wspace,addr)
				end
			end

			if( h["os_vendor"] )
				note = {
					:workspace => wspace,
					:host => addr,
					:type => 'host.os.nmap_fingerprint',
					:data => {
						:os_vendor   => h["os_vendor"],
						:os_family   => h["os_family"],
						:os_version  => h["os_version"],
						:os_accuracy => h["os_accuracy"]
					}
				}

				if(h["os_match"])
					note[:data][:os_match] = h['os_match']
				end

				report_note(note)
			end

			if (h["last_boot"])
				report_note(
					:workspace => wspace,
					:host => addr,
					:type => 'host.last_boot',
					:data => {
						:time => h["last_boot"]
					}
				)
			end

			if (h["trace"])
				hops = []
				h["trace"]["hops"].each do |hop|
					hops << { 
						"ttl"     => hop["ttl"].to_i,
						"address" => hop["ipaddr"].to_s,
						"rtt"     => hop["rtt"].to_f,
						"name"    => hop["host"].to_s
					}
				end
				report_note(
					:workspace => wspace,
					:host => addr,
					:type => 'host.nmap.traceroute',
					:data => {
						'port'  => h["trace"]["port"].to_i,
						'proto' => h["trace"]["proto"].to_s,
						'hops'  => hops
					}
				)
			end
			

			# Put all the ports, regardless of state, into the db.
			h["ports"].each { |p|
				# Localhost port results are pretty unreliable -- if it's
				# unknown, it's no good (possibly Windows-only)
				if (
					p["state"] == "unknown" &&
					h["status_reason"] == "localhost-response"
				)
					next
				end
				extra = ""
				extra << p["product"]   + " " if p["product"]
				extra << p["version"]   + " " if p["version"]
				extra << p["extrainfo"] + " " if p["extrainfo"]

				data = {}
				data[:workspace] = wspace
				if fix_services
					data[:proto] = nmap_msf_service_map(p["protocol"])
				else
					data[:proto] = p["protocol"].downcase
				end
				data[:port]  = p["portid"].to_i
				data[:state] = p["state"]
				data[:host]  = addr
				data[:info]  = extra if not extra.empty?
				if p["name"] != "unknown"
					data[:name] = p["name"]
				end
				report_service(data)
			}
		}

		REXML::Document.parse_stream(data, parser)
	end

	def nmap_msf_service_map(proto)
		return proto unless proto.kind_of? String
		case proto.downcase
		when "msrpc", "nfs-or-iis";         "dcerpc"
		when "netbios-ns";                  "netbios"
		when "netbios-ssn", "microsoft-ds"; "smb"
		when "ms-sql-s";                    "mssql"
		when "ms-sql-m";                    "mssql-m"
		when "postgresql";                  "postgres"
		when "http-proxy";                  "http"
		when "iiimsf";                      "db2"
		else
			proto.downcase
		end
	end

	def report_import_note(wspace,addr)
		if @import_filedata.kind_of?(Hash) && @import_filedata[:filename] && @import_filedata[:filename] !~ /msfe-nmap[0-9]{8}/
		report_note(
			:workspace => wspace,
			:host => addr,
			:type => 'host.imported',
			:data => @import_filedata.merge(:time=> Time.now.utc)
		)
		end
	end

	#
	# Import Nessus NBE files
	#
	def import_nessus_nbe_file(args={})
		filename = args[:filename]
		wspace = args[:wspace] || workspace

		data = ""
		::File.open(filename, 'rb') do |f|
			data = f.read(f.stat.size)
		end
		import_nessus_nbe(args.merge(:data => data))
	end

	def import_nessus_nbe(args={}, &block)
		data = args[:data]
		wspace = args[:wspace] || workspace
		bl = validate_ips(args[:blacklist]) ? args[:blacklist].split : []

		nbe_copy = data.dup
		# First pass, just to build the address map.
		addr_map = {}

		nbe_copy.each_line do |line|
			r = line.split('|')
			next if r[0] != 'results'
			next if r[4] != "12053"
			data = r[6]
			addr,hname = data.match(/([0-9\x2e]+) resolves as (.+)\x2e\\n/)[1,2]
			addr_map[hname] = addr
		end

		data.each_line do |line|
			r = line.split('|')
			next if r[0] != 'results'
			hname = r[2]
			if addr_map[hname]
				addr = addr_map[hname]
			else
				addr = hname # Must be unresolved, probably an IP address.
			end
			port = r[3]
			nasl = r[4]
			type = r[5]
			data = r[6]

			# If there's no resolution, or if it's malformed, skip it.
			next unless ipv4_validator(addr)

			if bl.include? addr
				next
			else
				yield(:address,addr) if block
			end

			# Match the NBE types with the XML severity ratings
			case type
			# log messages don't actually have any data, they are just
			# complaints about not being able to perform this or that test
			# because such-and-such was missing
			when "Log Message"; next
			when "Security Hole"; severity = 3
			when "Security Warning"; severity = 2
			when "Security Note"; severity = 1
			# a severity 0 means there's no extra data, it's just an open port
			else; severity = 0
			end
			if nasl == "11936"
				os = data.match(/The remote host is running (.*)\\n/)[1]
				report_note(
					:workspace => wspace,
					:host => addr,
					:type => 'host.os.nessus_fingerprint',
					:data => {
						:os => os.to_s.strip
					}
				)
			end
			handle_nessus(wspace, addr, port, nasl, severity, data)
		end
	end

	#
	# Of course they had to change the nessus format.
	#
	def import_openvas_xml(args={}, &block)
		filename = args[:filename]
		wspace = args[:wspace] || workspace

		raise DBImportError.new("No OpenVAS XML support. Please submit a patch to msfdev[at]metasploit.com")
	end

	#
	# Import IP360 XML v3 output
	#
	def import_ip360_xml_file(args={})
		filename = args[:filename]
		wspace = args[:wspace] || workspace

		data = ""
		::File.open(filename, 'rb') do |f|
			data = f.read(f.stat.size)
		end
		import_ip360_xml_v3(args.merge(:data => data))
	end

	#
	# Import Nessus XML v1 and v2 output
	#
	# Old versions of openvas exported this as well
	#
	def import_nessus_xml_file(args={})
		filename = args[:filename]
		wspace = args[:wspace] || workspace

		data = ""
		::File.open(filename, 'rb') do |f|
			data = f.read(f.stat.size)
		end

		if data.index("NessusClientData_v2")
			import_nessus_xml_v2(args.merge(:data => data))
		else
			import_nessus_xml(args.merge(:data => data))
		end
	end

	def import_nessus_xml(args={}, &block)
		data = args[:data]
		wspace = args[:wspace] || workspace
		bl = validate_ips(args[:blacklist]) ? args[:blacklist].split : []

		doc = rexmlify(data)
		doc.elements.each('/NessusClientData/Report/ReportHost') do |host|

			addr = nil
			hname = nil
			os = nil
			# If the name is resolved, the Nessus plugin for DNS
			# resolution should be there. If not, fall back to the
			# HostName
			host.elements.each('ReportItem') do |item|
				next unless item.elements['pluginID'].text == "12053"
				addr = item.elements['data'].text.match(/([0-9\x2e]+) resolves as/)[1]
				hname = host.elements['HostName'].text
			end
			addr ||= host.elements['HostName'].text
			next unless ipv4_validator(addr) # Skip resolved names and SCAN-ERROR.
			if bl.include? addr
				next
			else
				yield(:address,addr) if block
			end

			hinfo = {
				:workspace => wspace,
				:host => addr
			}

			# Record the hostname
			hinfo.merge!(:name => hname.to_s.strip) if hname
			report_host(hinfo)

			# Record the OS
			os ||= host.elements["os_name"]
			if os
				report_note(
					:workspace => wspace,
					:host => addr,
					:type => 'host.os.nessus_fingerprint',
					:data => {
						:os => os.text.to_s.strip
					}
				)
			end

			host.elements.each('ReportItem') do |item|
				nasl = item.elements['pluginID'].text
				port = item.elements['port'].text
				data = item.elements['data'].text
				severity = item.elements['severity'].text

				handle_nessus(wspace, addr, port, nasl, severity, data)
			end
		end
	end

	def import_nessus_xml_v2(args={}, &block)
		data = args[:data]
		wspace = args[:wspace] || workspace
		bl = validate_ips(args[:blacklist]) ? args[:blacklist].split : []
		
		#@host = {
				#'hname'             => nil,
				#'addr'              => nil,
				#'mac'               => nil,
				#'os'                => nil,
				#'ports'             => [ 'port' => {    'port'              	=> nil,
				#					'svc_name'              => nil,
				#					'proto'              	=> nil,
				#					'severity'              => nil,
				#					'nasl'              	=> nil,
				#					'description'           => nil,
				#					'cve'                   => [],
				#					'bid'                   => [],
				#					'xref'                  => []
				#				}
				#			]
				#}
		parser = Rex::Parser::NessusXMLStreamParser.new
		parser.on_found_host = Proc.new { |host|
			
			addr = host['addr'] || host['hname']
			
			next unless ipv4_validator(addr) # Catches SCAN-ERROR, among others.
			
			if bl.include? addr
				next
			else
				yield(:address,addr) if block
			end
			
	
			os = host['os']
			yield(:os,os) if block
			if os
				
				report_note(
					:workspace => wspace,
					:host => addr,
					:type => 'host.os.nessus_fingerprint',
					:data => {
						:os => os.to_s.strip
					}
				)
			end
	
			hname = host['hname']
			
			if hname
				report_host(
					:workspace => wspace,
					:host => addr,
					:name => hname.to_s.strip
				)
			end
	
			mac = host['mac']
			
			if mac
				report_host(
					:workspace => wspace,
					:host => addr,
					:mac  => mac.to_s.strip.upcase
				)
			end
			
			host['ports'].each do |item|
				next if item['port'] == 0
				msf = nil
				nasl = item['nasl'].to_s
				port = item['port'].to_s
				proto = item['proto'] || "tcp"
				name = item['svc_name']
				severity = item['severity']
				description = item['description']
				cve = item['cve'] 
				bid = item['bid']
				xref = item['xref']
				msf = item['msf']
				
				yield(:port,port) if block
				
				handle_nessus_v2(wspace, addr, port, proto, hname, nasl, severity, description, cve, bid, xref, msf)
	
			end
			yield(:end,hname) if block
		}
		
		REXML::Document.parse_stream(data, parser)
		
	end

	#
	# Import IP360's xml output
	#
	def import_ip360_xml_v3(args={}, &block)
		data = args[:data]
		wspace = args[:wspace] || workspace
		bl = validate_ips(args[:blacklist]) ? args[:blacklist].split : []
		
		# @aspl = {'vulns' => {'name' => { }, 'cve' => { }, 'bid' => { } } 
		# 'oses' => {'name' } }

		aspl_path = File.join(Msf::Config.data_directory, "ncircle", "ip360.aspl")
		
		if not ::File.exist?(aspl_path)
			raise DBImportError.new("The nCircle IP360 ASPL file is not present.\n    Download ASPL from nCircle VNE | Administer | Support | Resources, unzip it, and save it as " + aspl_path)
		end
		
		if not ::File.readable?(aspl_path)
			raise DBImportError.new("Could not read the IP360 ASPL XML file provided at " + aspl_path)
		end

		# parse nCircle ASPL file
		aspl = ""
		::File.open(aspl_path, "rb") do |f|
			aspl = f.read(f.stat.size)
		end
	
		@asplhash = nil
		parser = Rex::Parser::IP360ASPLXMLStreamParser.new
		parser.on_found_aspl = Proc.new { |asplh| 
			@asplhash = asplh
		}
		REXML::Document.parse_stream(aspl, parser)

		#@host = {'hname' => nil, 'addr' => nil, 'mac' => nil, 'os' => nil, 'hid' => nil,
                #         'vulns' => ['vuln' => {'vulnid' => nil, 'port' => nil, 'proto' => nil	} ],
                #         'apps' => ['app' => {'appid' => nil, 'svcid' => nil, 'port' => nil, 'proto' => nil } ],
                #         'shares' => []
                #        }

		# nCircle has some quotes escaped which causes the parser to break
		# we don't need these lines so just replace \" with "
		data.gsub!(/\\"/,'"')

		# parse nCircle Scan Output
		parser = Rex::Parser::IP360XMLStreamParser.new
		parser.on_found_host = Proc.new { |host|

			addr = host['addr'] || host['hname']
			
			next unless ipv4_validator(addr) # Catches SCAN-ERROR, among others.
			
			if bl.include? addr
				next
			else
				yield(:address,addr) if block
			end
	
			os = host['os']
			yield(:os, os) if block
			if os
				report_note(
					:workspace => wspace,
					:host => addr,
					:type => 'host.os.ip360_fingerprint',
					:data => {
						:os => @asplhash['oses'][os].to_s.strip
					}
				)
			end
	
			hname = host['hname']
			
			if hname
				report_host(
					:workspace => wspace,
					:host => addr,
					:name => hname.to_s.strip
				)
			end
	
			mac = host['mac']
			
			if mac
				report_host(
					:workspace => wspace,
					:host => addr,
					:mac  => mac.to_s.strip.upcase
				)
			end

			host['apps'].each do |item|
				port = item['port'].to_s
				proto = item['proto'].to_s

				handle_ip360_v3_svc(wspace, addr, port, proto, hname)
			end

			
			host['vulns'].each do |item|
				vulnid = item['vulnid'].to_s
				port = item['port'].to_s
				proto = item['proto'] || "tcp"
				vulnname = @asplhash['vulns']['name'][vulnid]
				cves = @asplhash['vulns']['cve'][vulnid]
				bids = @asplhash['vulns']['bid'][vulnid]
				
				yield(:port, port) if block
				
				handle_ip360_v3_vuln(wspace, addr, port, proto, hname, vulnid, vulnname, cves, bids)
	
			end

			yield(:end, hname) if block
		}
		
		REXML::Document.parse_stream(data, parser)
	end

	#
	# Import Qualys' xml output
	#
	def import_qualys_xml_file(args={})
		filename = args[:filename]
		wspace = args[:wspace] || workspace

		data = ""
		::File.open(filename, 'rb') do |f|
			data = f.read(f.stat.size)
		end
		import_qualys_xml(args.merge(:data => data))
	end

	def import_qualys_xml(args={}, &block)
		data = args[:data]
		wspace = args[:wspace] || workspace
		bl = validate_ips(args[:blacklist]) ? args[:blacklist].split : []


		doc = rexmlify(data)
		doc.elements.each('/SCAN/IP') do |host|
			addr  = host.attributes['value']
			if bl.include? addr
				next
			else
				yield(:address,addr) if block
			end
			hname = host.attributes['name'] || ''

			report_host(:workspace => wspace, :host => addr, :name => hname, :state => Msf::HostState::Alive)

			if host.elements["OS"]
				hos = host.elements["OS"].text
				report_note(
					:workspace => wspace,
					:host => addr,
					:type => 'host.os.qualys_fingerprint',
					:data => {
						:os => hos
					}
				)
			end

			# Open TCP Services List (Qualys ID 82023)
			services_tcp = host.elements["SERVICES/CAT/SERVICE[@number='82023']/RESULT"]
			if services_tcp
				services_tcp.text.scan(/([0-9]+)\t(.*?)\t.*?\t([^\t\n]*)/) do |match|
					if match[2] == nil or match[2].strip == 'unknown'
						name = match[1].strip
					else
						name = match[2].strip
					end
					handle_qualys(wspace, addr, match[0].to_s, 'tcp', 0, nil, nil, name)
				end
			end
			# Open UDP Services List (Qualys ID 82004)
			services_udp = host.elements["SERVICES/CAT/SERVICE[@number='82004']/RESULT"]
			if services_udp
				services_udp.text.scan(/([0-9]+)\t(.*?)\t.*?\t([^\t\n]*)/) do |match|
					if match[2] == nil or match[2].strip == 'unknown'
						name = match[1].strip
					else
						name = match[2].strip
					end
					handle_qualys(wspace, addr, match[0].to_s, 'udp', 0, nil, nil, name)
				end
			end

			# VULNS are confirmed, PRACTICES are unconfirmed vulnerabilities
			host.elements.each('VULNS/CAT | PRACTICES/CAT') do |cat|
				port = cat.attributes['port']
				protocol = cat.attributes['protocol']
				cat.elements.each('VULN | PRACTICE') do |vuln|
					refs = []
					qid = vuln.attributes['number']
					severity = vuln.attributes['severity']
					vuln.elements.each('VENDOR_REFERENCE_LIST/VENDOR_REFERENCE') do |ref|
						refs.push(ref.elements['ID'].text.to_s)
					end
					vuln.elements.each('CVE_ID_LIST/CVE_ID') do |ref|
						refs.push('CVE-' + /C..-([0-9\-]{9})/.match(ref.elements['ID'].text.to_s)[1])
					end
					vuln.elements.each('BUGTRAQ_ID_LIST/BUGTRAQ_ID') do |ref|
						refs.push('BID-' + ref.elements['ID'].text.to_s)
					end

					handle_qualys(wspace, addr, port, protocol, qid, severity, refs)
				end
			end
		end
	end

	def import_ip_list_file(args={})
		filename = args[:filename]
		wspace = args[:wspace] || workspace

		data = ""
		::File.open(filename, 'rb') do |f|
			data = f.read(f.stat.size)
		end
		import_ip_list(args.merge(:data => data))
	end

	def import_ip_list(args={}, &block)
		data = args[:data]
		wspace = args[:wspace] || workspace
		bl = validate_ips(args[:blacklist]) ? args[:blacklist].split : []

		data.each_line do |ip|
			ip.strip!
			if bl.include? ip
				next
			else
				yield(:address,ip) if block
			end
			host = find_or_create_host(:workspace => wspace, :host=> ip, :state => Msf::HostState::Alive)
		end
	end

	def import_amap_log_file(args={})
		filename = args[:filename]
		wspace = args[:wspace] || workspace
		data = ""
		::File.open(filename, 'rb') do |f|
			data = f.read(f.stat.size)
		end
		
		case import_filetype_detect(data)
		when :amap_log
			import_amap_log(args.merge(:data => data))
		when :amap_mlog
			import_amap_mlog(args.merge(:data => data))
		else
			raise DBImportError.new("Could not determine file type")
		end
	end

	def import_amap_log(args={}, &block)
		data = args[:data]
		wspace = args[:wspace] || workspace
		bl = validate_ips(args[:blacklist]) ? args[:blacklist].split : []

		data.each_line do |line|
			next if line =~ /^#/
			next if line !~ /^Protocol on ([^:]+):([^\x5c\x2f]+)[\x5c\x2f](tcp|udp) matches (.*)$/
			addr   = $1
			next if bl.include? addr
			port   = $2.to_i
			proto  = $3.downcase
			name   = $4
			host = find_or_create_host(:workspace => wspace, :host => addr, :state => Msf::HostState::Alive)
			next if not host
			yield(:address,addr) if block
			info = {
				:workspace => wspace,
				:host => host,
				:proto => proto,
				:port => port
			}
			if name != "unidentified"
				info[:name] = name
			end
			service = find_or_create_service(info)
		end
	end

	def import_amap_mlog(args={}, &block)
		data = args[:data]
		wspace = args[:wspace] || workspace
		bl = validate_ips(args[:blacklist]) ? args[:blacklist].split : []

		data.each_line do |line|
			next if line =~ /^#/
			r = line.split(':')
			next if r.length < 6

			addr   = r[0]
			next if bl.include? addr
			port   = r[1].to_i
			proto  = r[2].downcase
			status = r[3]
			name   = r[5]
			next if status != "open"

			host = find_or_create_host(:workspace => wspace, :host => addr, :state => Msf::HostState::Alive)
			next if not host
			yield(:address,addr) if block
			info = {
				:workspace => wspace,
				:host => host,
				:proto => proto,
				:port => port
			}
			if name != "unidentified"
				info[:name] = name
			end
			service = find_or_create_service(info)
		end
	end

	def unserialize_object(xml_elem, allow_yaml = false)
		string = xml_elem.text.to_s.strip
		return string unless string.is_a?(String)
		return nil if not string
		return nil if string.empty?

		begin
			# Validate that it is properly formed base64 first
			if string.gsub(/\s+/, '') =~ /^([a-z0-9A-Z\+\/=]+)$/
				Marshal.load($1.unpack("m")[0])
			else
				if allow_yaml
					begin
						YAML.load(string)
					rescue
						dlog("Badly formatted YAML: '#{string}'")
						string
					end
				else
					string
				end
			end
		rescue ::Exception => e
			if allow_yaml
				YAML.load(string) rescue string
			else
				string
			end
		end
	end

	def normalize_host(host)
		# If the host parameter is a Session, try to extract its address
		if host.respond_to?('target_host')
			thost = host.target_host
			tpeer = host.tunnel_peer
			if tpeer and (!thost or thost.empty?)
				thost = tpeer.split(":")[0]
			end
			host = thost
		end
		host
	end

protected

	#
	# This holds all of the shared parsing/handling used by the
	# Nessus NBE and NESSUS v1 methods
	#
	def handle_nessus(wspace, addr, port, nasl, severity, data)
		# The port section looks like:
		#   http (80/tcp)
		p = port.match(/^([^\(]+)\((\d+)\/([^\)]+)\)/)
		return if not p

		report_host(:workspace => wspace, :host => addr, :state => Msf::HostState::Alive)
		name = p[1].strip
		port = p[2].to_i
		proto = p[3].downcase

		info = { :workspace => wspace, :host => addr, :port => port, :proto => proto }
		if name != "unknown" and name[-1,1] != "?"
			info[:name] = name
		end
		report_service(info)

		return if not nasl

		data.gsub!("\\n", "\n")

		refs = []

		if (data =~ /^CVE : (.*)$/)
			$1.gsub(/C(VE|AN)\-/, '').split(',').map { |r| r.strip }.each do |r|
				refs.push('CVE-' + r)
			end
		end

		if (data =~ /^BID : (.*)$/)
			$1.split(',').map { |r| r.strip }.each do |r|
				refs.push('BID-' + r)
			end
		end

		if (data =~ /^Other references : (.*)$/)
			$1.split(',').map { |r| r.strip }.each do |r|
				ref_id, ref_val = r.split(':')
				ref_val ? refs.push(ref_id + '-' + ref_val) : refs.push(ref_id)
			end
		end

		nss = 'NSS-' + nasl.to_s

		vuln_info = {
			:workspace => wspace,
			:host => addr,
			:port => port,
			:proto => proto,
			:name => nss,
			:info => data,
			:refs => refs
		}
		report_vuln(vuln_info)
	end

	#
	# NESSUS v2 file format has a dramatically different layout
	# for ReportItem data
	#
	def handle_nessus_v2(wspace,addr,port,proto,name,nasl,severity,description,cve,bid,xref,msf)

		report_host(:workspace => wspace, :host => addr, :state => Msf::HostState::Alive)

		info = { :workspace => wspace, :host => addr, :port => port, :proto => proto }
		if name != "unknown" and name[-1,1] != "?"
			info[:name] = name
		end

		if port.to_i != 0
			report_service(info)
		end

		return if nasl == "0"

		refs = []

		cve.each do |r|
			r.to_s.gsub!(/C(VE|AN)\-/, '')
			refs.push('CVE-' + r.to_s)
		end if cve

		bid.each do |r|
			refs.push('BID-' + r.to_s)
		end if bid

		xref.each do |r|
			ref_id, ref_val = r.to_s.split(':')
			ref_val ? refs.push(ref_id + '-' + ref_val) : refs.push(ref_id)
		end if xref
		
		msfref = "MSF-" << msf if msf
		refs.push msfref if msfref
		
		nss = 'NSS-' + nasl

		vuln = {
			:workspace => wspace,
			:host => addr,
			:name => nss,
			:info => description ? description : "",
			:refs => refs
		}

		if port.to_i != 0
			vuln[:port]  = port
			vuln[:proto] = proto
		end

		report_vuln(vuln)
	end

	#
	# IP360 v3 vuln  
	#
	def handle_ip360_v3_svc(wspace,addr,port,proto,hname)

		report_host(:workspace => wspace, :host => addr, :state => Msf::HostState::Alive)

		info = { :workspace => wspace, :host => addr, :port => port, :proto => proto }
		if hname != "unknown" and hname[-1,1] != "?"
			info[:name] = hname
		end

		if port.to_i != 0
			report_service(info)
		end
	end  #handle_ip360_v3_svc

	#
	# IP360 v3 vuln  
	#
	def handle_ip360_v3_vuln(wspace,addr,port,proto,hname,vulnid,vulnname,cves,bids)

		report_host(:workspace => wspace, :host => addr, :state => Msf::HostState::Alive)

		info = { :workspace => wspace, :host => addr, :port => port, :proto => proto }
		if hname != "unknown" and hname[-1,1] != "?"
			info[:name] = hname
		end

		if port.to_i != 0
			report_service(info)
		end

		refs = []

		cves.split(/,/).each do |cve|
			refs.push(cve.to_s)
		end if cves

		bids.split(/,/).each do |bid|
			refs.push('BID-' + bid.to_s)
		end if bids

		description = nil   # not working yet
		vuln = {
			:workspace => wspace,
			:host => addr,
			:name => vulnname,
			:info => description ? description : "",
			:refs => refs
		}

		if port.to_i != 0
			vuln[:port]  = port
			vuln[:proto] = proto
		end

		report_vuln(vuln)
	end  #handle_ip360_v3_vuln

	#
	# Qualys report parsing/handling
	#
	def handle_qualys(wspace, addr, port, protocol, qid, severity, refs, name=nil)

		port = port.to_i

		info = { :workspace => wspace, :host => addr, :port => port, :proto => protocol }
		if name and name != 'unknown'
			info[:name] = name
		end

		if info[:host] && info[:port] && info[:proto]
			report_service(info)
		end

		return if qid == 0

		if addr
			report_vuln(
				:workspace => wspace,
				:host => addr,
				:port => port,
				:proto => protocol,
				:name => 'QUALYS-' + qid,
				:refs => refs
			)
		end
	end

	def process_nexpose_data_sxml_refs(vuln)
		refs = []
		vid = vuln.attributes['id'].to_s.downcase
		vry = vuln.attributes['resultCode'].to_s.upcase

		# Only process vuln-exploitable and vuln-version statuses
		return if vry !~ /^V[VE]$/

		refs = []
		vuln.elements.each('id') do |ref|
			rtyp = ref.attributes['type'].to_s.upcase
			rval = ref.text.to_s.strip
			case rtyp
			when 'CVE'
				refs << rval.gsub('CAN', 'CVE')
			when 'MS' # obsolete?
				refs << "MSB-MS-#{rval}"
			else
				refs << "#{rtyp}-#{rval}"
			end
		end

		refs << "NEXPOSE-#{vid}"
		refs
	end

	#
	# NeXpose vuln lookup
	#
	def nexpose_vuln_lookup(wspace, doc, vid, refs, host, serv=nil)
		doc.elements.each("/NexposeReport/VulnerabilityDefinitions/vulnerability[@id = '#{vid}']]") do |vulndef|

			title = vulndef.attributes['title']
			pciSeverity = vulndef.attributes['pciSeverity']
			cvss_score = vulndef.attributes['cvssScore']
			cvss_vector = vulndef.attributes['cvssVector']

			vulndef.elements['references'].elements.each('reference') do |ref|
				if ref.attributes['source'] == 'BID'
					refs[ 'BID-' + ref.text ] = true
				elsif ref.attributes['source'] == 'CVE'
					# ref.text is CVE-$ID
					refs[ ref.text ] = true
				elsif ref.attributes['source'] == 'MS'
					refs[ 'MSB-MS-' + ref.text ] = true
				end
			end

			refs[ 'NEXPOSE-' + vid.downcase ] = true

			vuln = find_or_create_vuln(
				:workspace => wspace,
				:host => host,
				:service => serv,
				:name => 'NEXPOSE-' + vid.downcase,
				:info => title)

			rids = []
			refs.keys.each do |r|
				rids << find_or_create_ref(:name => r)
			end

			vuln.refs << (rids - vuln.refs)
		end
	end
end

end

