module Msf

###
#
# This module provides methods for brute forcing authentication
#
###

module Auxiliary::AuthBrute

def initialize(info = {})
	super

	register_options([
	OptString.new('USERNAME', [ false, 'A specific username to authenticate as' ]),
	OptString.new('PASSWORD', [ false, 'A specific password to authenticate with' ]),
	OptPath.new('USER_FILE', [ false, "File containing usernames, one per line" ]),
	OptPath.new('PASS_FILE', [ false, "File containing passwords, one per line" ]),
	OptPath.new('USERPASS_FILE',  [ false, "File containing users and passwords separated by space, one pair per line" ]),
	OptInt.new('BRUTEFORCE_SPEED', [ true, "How fast to bruteforce, from 0 to 5", 5]),
	OptBool.new('VERBOSE', [ true, "Whether to print output for all attempts", true]),
	OptBool.new('BLANK_PASSWORDS', [ true, "Try blank passwords for all users", true]),
	OptBool.new('STOP_ON_SUCCESS', [ true, "Stop guessing when a credential works for a host", false]),
	], Auxiliary::AuthBrute)
	
	register_advanced_options([
		OptBool.new('REMOVE_USER_FILE', [ true, "Automatically delete the USER_FILE on module completion", false]),
		OptBool.new('REMOVE_PASS_FILE', [ true, "Automatically delete the PASS_FILE on module completion", false]),
		OptBool.new('REMOVE_USERPASS_FILE', [ true, "Automatically delete the USERPASS_FILE on module completion", false])
	], Auxiliary::AuthBrute)

end

# Checks all three files for usernames and passwords, and combines them into
# one credential list to apply against the supplied block. The block (usually
# something like do_login(user,pass) ) is responsible for actually recording
# success and failure in its own way; each_user_pass() will only respond to
# a return value of :done (which will signal to end all processing) and
# to :next_user (which will cause that username to be skipped for subsequent
# password guesses). Other return values won't affect the processing of the
# list.
def each_user_pass(&block)
	# Class variables to track credential use (for threading)
	@@credentials_tried = {}
	@@credentials_skipped = {}
	credentials = extract_word_pair(datastore['USERPASS_FILE'])
	users       = extract_words(datastore['USER_FILE'])
	passwords   = extract_words(datastore['PASS_FILE'])

	cleanup_files()

	translate_proto_datastores()

	if datastore['USERNAME']
		users.unshift datastore['USERNAME']
		credentials = prepend_chosen_username(datastore['USERNAME'],credentials)
	end

	if datastore['PASSWORD']
		passwords.unshift datastore['PASSWORD']
		credentials = prepend_chosen_password(datastore['PASSWORD'],credentials)
	end

	if datastore['BLANK_PASSWORDS']
		credentials = gen_blank_passwords(users,credentials)
	end

	credentials.concat(combine_users_and_passwords(users,passwords))
	credentials = just_uniq_passwords(credentials) if @strip_usernames
	fq_rest = "%s:%s:%s" % [datastore['RHOST'], datastore['RPORT'], "all remaining users"]

	credentials.each do |u,p|
		break if @@credentials_skipped[fq_rest]
		fq_user = "%s:%s:%s" % [datastore['RHOST'], datastore['RPORT'], u]
		userpass_sleep_interval unless @@credentials_tried.empty?
		next if @@credentials_skipped[fq_user]
		next if @@credentials_tried[fq_user] == p
		ret = block.call(u,p)
		case ret
		when :abort # Skip the current host entirely.
		break
		when :next_user # This means success for that user.
			@@credentials_skipped[fq_user] = p
			if datastore['STOP_ON_SUCCESS'] # See?
				@@credentials_skipped[fq_rest] = true
			end
		when :skip_user # Skip the user in non-success cases. 
			@@credentials_skipped[fq_user] = p
		when :connection_error # Report an error, skip this cred, but don't abort.
			vprint_error "#{datastore['RHOST']}:#{datastore['RPORT']} - Connection error, skipping '#{u}':'#{p}'"
		end
	@@credentials_tried[fq_user] = p
	end
	return
end

# Takes protocol-specific username and password fields, and,
# if present, prefer those over any given USERNAME or PASSWORD.
# Note, these special username/passwords should get deprecated
# some day. Note2: Don't use with SMB and FTP at the same time!
def translate_proto_datastores
	switched = false
	['SMBUser','FTPUSER'].each do |u|
		if datastore[u] and !datastore[u].empty?
			datastore['USERNAME'] = datastore[u]
		end
	end
	['SMBPass','FTPPASS'].each do |p|
		if datastore[p] and !datastore[p].empty?
			datastore['PASSWORD'] = datastore[p]
		end
	end
end

def just_uniq_passwords(credentials)
	credentials.map{|x| ["",x[1]]}.uniq
end

def prepend_chosen_username(user,cred_array)
	cred_array.map {|pair| [user,pair[1]]} + cred_array
end

def prepend_chosen_password(pass,cred_array)
	cred_array.map {|pair| [pair[0],pass]} + cred_array
end

def gen_blank_passwords(user_array,cred_array)
	blank_passwords = []
	unless user_array.empty?
		blank_passwords.concat(user_array.map {|u| [u,""]})
	end
	unless cred_array.empty?
		cred_array.each {|u,p| blank_passwords << [u,""]}
	end
	return(blank_passwords + cred_array)
end

def combine_users_and_passwords(user_array,pass_array)
	combined_array = []
	if (user_array + pass_array).empty?
		return []
	end
	if pass_array.empty?
		combined_array = user_array.map {|u| [u,""] }
	elsif user_array.empty?
		combined_array = pass_array.map {|p| ["",p] }
	else
		user_array.each do |u|
			pass_array.each do |p|
				combined_array << [u,p]
			end
		end
	end

	# Move datastore['USERNAME'] and datastore['PASSWORD'] to the front of the list.
	creds = [ [], [], [], [] ] # userpass, pass, user, rest
	combined_array.each do |pair|
		if pair == [datastore['USERNAME'],datastore['PASSWORD']]
			creds[0] << pair
		elsif pair[1] == datastore['PASSWORD']
			creds[1] <<  pair
		elsif pair[0] == datastore['USERNAME']
			creds[2] <<  pair
		else
			creds[3] << pair
		end
	end
	return creds[0] + creds[1] + creds[2] + creds[3]
end

def extract_words(wordfile)
	return [] unless wordfile && File.readable?(wordfile)
	begin
		words = File.open(wordfile) {|f| f.read(f.stat.size)}
	rescue
		return
	end
	save_array = words.split(/\r?\n/)
	return save_array
end

def extract_word_pair(wordfile)
	return [] unless wordfile && File.readable?(wordfile)
	creds = []
	begin
		upfile_contents = File.open(wordfile) {|f| f.read(f.stat.size)}
	rescue
		return []
	end
	upfile_contents.split(/\n/).each do |line|
		user,pass = line.split(/\s+/,2).map { |x| x.strip }
		creds << [user.to_s, pass.to_s]
	end
	return creds
end

def userpass_sleep_interval
	sleep_time = case datastore['BRUTEFORCE_SPEED'].to_i
	when 0; 60 * 5
	when 1; 15
	when 2; 1
	when 3; 0.5
	when 4; 0.1
	else; 0
	end
	::IO.select(nil,nil,nil,sleep_time) unless sleep_time == 0
end

def vprint_status(msg='')
	return if not datastore['VERBOSE']
	print_status(msg)
end

def vprint_error(msg='')
	return if not datastore['VERBOSE']
	print_error(msg)
end

def vprint_good(msg='')
	return if not datastore['VERBOSE']
	print_good(msg)
end


# This method deletes the dictionary files if requested
def cleanup_files
	path = datastore['USERPASS_FILE']
	if path and datastore['REMOVE_USERPASS_FILE']
		::File.unlink(path) rescue nil
	end
	
	path = datastore['USER_FILE']
	if path and datastore['REMOVE_USER_FILE']
		::File.unlink(path) rescue nil
	end
	
	path = datastore['PASS_FILE']
	if path and datastore['REMOVE_PASS_FILE']
		::File.unlink(path) rescue nil
	end
end

end
end

