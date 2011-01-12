##
# $Id$
##

##
# This file is part of the Metasploit Framework and may be subject to
# redistribution and commercial restrictions. Please see the Metasploit
# Framework web site for more information on licensing and terms of use.
# http://metasploit.com/framework/
##

require 'msf/core'
require 'rex'
require 'msf/core/post/windows/registry'

class Metasploit3 < Msf::Post

	include Msf::Post::Registry

	def initialize(info={})
		super( update_info( info,
				'Name'          => 'Enumerate Installed Applications',
				'Description'   => %q{ This module will enumerate installed application on a target host},
				'License'       => MSF_LICENSE,
				'Author'        => [ 'Carlos Perez <carlos_perez[at]darkoperator.com>'],
				'Version'       => '$Revision$',
				'Platform'      => [ 'windows' ],
				'SessionTypes'  => [ 'meterpreter' ]
			))

	end

	def app_list
		tbl = Rex::Ui::Text::Table.new(
			'Header'  => "Installed Applications",
			'Indent'  => 1,
			'Columns' =>
			[
				"Name",
				"Version"
			])
		appkeys = ['HKLM\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Uninstall',
			'HKCU\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Uninstall' ]
		apps = []
		appkeys.each do |keyx86|
			registry_enumkeys(keyx86).each do |ak|
				apps << keyx86 +"\\" + ak
			end
		end

		t = []
		while(not apps.empty?)
			
			1.upto(16) do
				t << framework.threads.spawn("Module(#{self.refname})", false, apps.shift) do |k|
					begin
						dispnm = registry_getvaldata("#{k}","DisplayName")
						dispversion = registry_getvaldata("#{k}","DisplayVersion")
						tbl << [dispnm,dispversion]
					rescue
					end
				end

			end
			t.map{|x| x.join }
		end
		
		print_line("\n" + tbl.to_s + "\n")
	end

	def run
		print_status("Enumerating applications installed on #{sysinfo['Computer']}")
		app_list
	end

end
