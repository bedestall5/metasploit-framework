#!/usr/bin/env ruby
#
# $Id$
#
# This script lists all modules with their targets
#
# $Revision$
#

msfbase = File.symlink?(__FILE__) ? File.readlink(__FILE__) : __FILE__
$:.unshift(File.join(File.dirname(msfbase), '..', 'lib'))

require 'rex'
require 'msf/ui'
require 'msf/base'

Indent = '    '

# Initialize the simplified framework instance.
$framework = Msf::Simple::Framework.create('DisableDatabase' => true)

tbl = Rex::Ui::Text::Table.new(
	'Header'  => 'Module Targets',
	'Indent'  => Indent.length,
	'Columns' => [ 'Module name','Target' ]
)

all_modules = $framework.exploits

all_modules.each_module { |name, mod|
	x = mod.new
	x.targets.each do |targ|
		tbl << [ x.fullname, targ.name ]
	end
}

puts tbl.to_s
