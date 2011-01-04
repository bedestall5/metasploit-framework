module Msf
class DBManager

class Campaign < ActiveRecord::Base
	has_one :email_template
	has_one :web_template
	has_one :attachment
	has_many :email_addresses
	has_many :clients

	extend SerializedPrefs

	serialize :prefs

	# General settings
	serialized_prefs_attr_accessor :payload_lhost, :listener_lhost

	# Email settings
	serialized_prefs_attr_accessor :do_email
	serialized_prefs_attr_accessor :smtp_server, :smtp_port, :smtp_ssl
	serialized_prefs_attr_accessor :smtp_user, :smtp_pass
	serialized_prefs_attr_accessor :mailfrom

	# Web settings
	serialized_prefs_attr_accessor :do_web
	serialized_prefs_attr_accessor :web_uripath, :web_urihost, :web_srvport, :web_srvhost
	serialized_prefs_attr_accessor :web_ssl

	# Executable settings
	serialized_prefs_attr_accessor :do_exe_gen
	serialized_prefs_attr_accessor :exe_lport
	serialized_prefs_attr_accessor :exe_name

end

end
end

