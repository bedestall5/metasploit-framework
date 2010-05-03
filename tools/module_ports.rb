#!/usr/bin/env ruby
#
# $Id$
#
# This script lists each module by the default ports it uses
#
# $Revision$
#

msfbase = File.symlink?(__FILE__) ? File.readlink(__FILE__) : __FILE__
$:.unshift(File.join(File.dirname(msfbase), '..', 'lib'))

require 'rex'
require 'msf/ui'
require 'msf/base'

def lic_short(l)
	if (l.class == Array)
		l = l[0]
	end

	case l
	when MSF_LICENSE
		'MSF'
	when GPL_LICENSE
		'GPL'
	when BSD_LICENSE
		'BSD'
	when ARTISTIC_LICENSE
		'ART'
	else
		'UNK'
	end
end

Indent = '    '

# Initialize the simplified framework instance.
$framework = Msf::Simple::Framework.create


tbl = Rex::Ui::Text::Table.new(
	'Header'  => 'Licensed Modules',
	'Indent'  => Indent.length,
	'Columns' => [ 'License','Type', 'Name' ]
)

licenses = {}

all_modules = $framework.exploits.merge($framework.auxiliary)
all_ports = {}

all_modules.each_module { |name, mod|
	x = mod.new
	ports = []

	if x.datastore['RPORT']
		ports << x.datastore['RPORT']
	end

	if(x.respond_to?('autofilter_ports'))
		x.autofilter_ports.each do |rport|
			ports << rport
		end
	end
	ports = ports.map{|p| p.to_i}
	ports.uniq!
	ports.sort{|a,b| a <=> b}.each do |rport|
		# Just record the first occurance.
		all_ports[rport] = x.fullname unless all_ports[rport]
	end
}

all_ports.sort.each { |k,v|
	puts "%5s # %s" % [k,v]
}



