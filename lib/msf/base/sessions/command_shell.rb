require 'msf/base'

module Msf
module Sessions

###
#
# This class provides basic interaction with a command shell on the remote
# endpoint.  This session is initialized with a stream that will be used
# as the pipe for reading and writing the command shell.
#
###
class CommandShell

	#
	# This interface supports basic interaction.
	#
	include Msf::Session::Basic

	#
	# This interface supports interacting with a single command shell.
	#
	include Msf::Session::Provider::SingleCommandShell

	#
	# Returns the type of session.
	#
	def self.type
		"shell"
	end

	#
	# Find out of the script exists (and if so, which path)
	#
	ScriptBase     = Msf::Config.script_directory + Msf::Config::FileSep + "shell"
	UserScriptBase = Msf::Config.user_script_directory + Msf::Config::FileSep + "shell"

	def self.find_script_path(script)
		# Find the full file path of the specified argument
		check_paths =
			[
				script,
				ScriptBase + Msf::Config::FileSep + "#{script}",
				ScriptBase + Msf::Config::FileSep + "#{script}.rb",
				UserScriptBase + Msf::Config::FileSep + "#{script}",
				UserScriptBase + Msf::Config::FileSep + "#{script}.rb"
			]

		full_path = nil

		# Scan all of the path combinations
		check_paths.each { |path|
			if ::File.exists?(path)
				full_path = path
				break
			end
		}

		full_path
	end


	#
	# Returns the session description.
	#
	def desc
		"Command shell"
	end

	#
	# Explicitly runs a command.
	#
	def run_cmd(cmd)
		shell_command(cmd)
	end

	#
	# Calls the class method.
	#
	def type
		self.class.type
	end

	#
	# The shell will have been initialized by default.
	#
	def shell_init
		return true
	end

	#
	# Executes the supplied script.
	#
	def execute_script(script, args)
		full_path = self.class.find_script_path(script)

		# No path found?  Weak.
		if full_path.nil?
			print_error("The specified script could not be found: #{script}")
			return true
		end

		o = Rex::Script::Shell.new(self, full_path)
		o.run(args)
	end


	#
	# Explicitly run a single command, return the output.
	#
	def shell_command(cmd)
		# Send the command to the session's stdin.
		shell_write(cmd + "\n")

		# wait up to 5 seconds for some data to appear
		if (not (::IO.select([rstream], nil, nil, 5)))
			return nil
		end

		# get the output that we have ready
		shell_read(-1, 0.01)
	end


	#
	# Read data until we find the token
	#
	def shell_read_until_token(token, wanted_idx = 0, timeout = 10)
		if (wanted_idx == 0)
			parts_needed = 2
		else
			parts_needed = 1 + (wanted_idx * 2)
		end

		# Read until we get the data between two tokens or absolute timeout.
		begin
			Timeout::timeout(timeout) do
				buf = ''
				idx = nil
				loop do
					if (tmp = shell_read(-1, 2))
						buf << tmp

						# see if we have the wanted idx
						parts = buf.split(token, -1)
						if (parts.length == parts_needed)
							# cause another prompt to appear (just in case)
							shell_write("\n")
							return parts[wanted_idx]
						end
					end
				end
			end
		rescue
			# nothing, just continue
		end

		# failed to get any data or find the token!
		nil
	end

	#
	# Explicitly run a single command and return the output.
	# This version uses a marker to denote the end of data (instead of a timeout).
	#
	def shell_command_token_unix(cmd)
		# read any pending data
		buf = shell_read(-1, 0.01)
		token = ::Rex::Text.rand_text_alpha(32)

		# Send the command to the session's stdin.
		# NOTE: if the session echoes input we don't need to echo the token twice.
		shell_write(cmd + ";echo #{token}\n")
		shell_read_until_token(token)
	end

	#
	# Explicitly run a single command and return the output.
	# This version uses a marker to denote the end of data (instead of a timeout).
	#
	def shell_command_token_win32(cmd)
		# read any pending data
		buf = shell_read(-1, 0.01)
		token = ::Rex::Text.rand_text_alpha(32)

		# Send the command to the session's stdin.
		# NOTE: if the session echoes input we don't need to echo the token twice.
		shell_write(cmd + "&echo #{token}\n")
		shell_read_until_token(token, 1)
	end


	#
	# Read from the command shell.
	#
	def shell_read(length=-1, timeout=1)
		begin
			rv = rstream.get_once(length, timeout)
			framework.events.on_session_output(self, rv) if rv
			return rv
		rescue ::Exception => e
			shell_close
			raise e
		end
	end

	#
	# Writes to the command shell.
	#
	def shell_write(buf)
		return if not buf

		begin
			framework.events.on_session_command(self, buf.strip)
			rstream.write(buf)
		rescue ::Exception => e
			shell_close
			raise e
		end
	end

	#
	# Closes the shell.
	#
	def shell_close()
		begin
			rstream.close
		rescue ::Exception
		end
		self.kill
	end

	#
	# Execute any specified auto-run scripts for this session
	#
	def process_autoruns(datastore)
		# Read the initial output and mash it into a single line
		if (not self.info or self.info.empty?)
			initial_output = shell_read(-1, 0.01)
			if (initial_output)
				initial_output.gsub!(/[\r\n\t]+/, ' ')
				initial_output.strip!

				# Set the inital output to .info
				self.info = initial_output
			end
		end

		if (datastore['InitialAutoRunScript'] && datastore['InitialAutoRunScript'].empty? == false)
			args = datastore['InitialAutoRunScript'].split
			print_status("Session ID #{sid} (#{tunnel_to_s}) processing InitialAutoRunScript '#{datastore['InitialAutoRunScript']}'")
			execute_script(args.shift, args)
		end

		if (datastore['AutoRunScript'] && datastore['AutoRunScript'].empty? == false)
			args = datastore['AutoRunScript'].split
			print_status("Session ID #{sid} (#{tunnel_to_s}) processing AutoRunScript '#{datastore['AutoRunScript']}'")
			execute_script(args.shift, args)
		end
	end

protected

	# Override the basic session interaction to use shell_read and
	# shell_write instead of operating on rstream directly.
	def _interact
		framework.events.on_session_interact(self)

		fds = [rstream.fd, user_input.fd]
		while self.interacting
			sd = Rex::ThreadSafe.select(fds, nil, fds, 0.5)
			next if not sd

			if sd[0].include? rstream.fd
				user_output.print(shell_read)
			end
			if sd[0].include? user_input.fd
				shell_write(user_input.gets)
			end
		end
	end
end

end
end

