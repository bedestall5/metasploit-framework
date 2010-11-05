#!/usr/bin/env ruby
#
# $Id$
#
# This script lists each module with its references
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
	'Header'  => 'Module References',
	'Indent'  => Indent.length,
	'Columns' => [ 'Module', 'Reference' ]
)

$framework.payloads.each_module { |name, mod|
	x = mod.new
	x.references.each do |r|
		tbl << [ 'payload/' + name, r.ctx_id + '-' + r.ctx_val ]
	end
}

$framework.exploits.each_module { |name, mod|
	x = mod.new
	x.references.each do |r|
		tbl << [ 'exploit/' + name, r.ctx_id + '-' + r.ctx_val ]
	end
}

$framework.nops.each_module { |name, mod|
	x = mod.new
	x.references.each do |r|
		tbl << [ 'nop/' + name, r.ctx_id + '-' + r.ctx_val ]
	end
}
$framework.encoders.each_module { |name, mod|
	x = mod.new
	x.references.each do |r|
		tbl << [ 'encoder/' + name, r.ctx_id + '-' + r.ctx_val ]
	end
}
$framework.auxiliary.each_module { |name, mod|
	x = mod.new
	x.references.each do |r|
		tbl << [ 'auxiliary/' + name, r.ctx_id + '-' + r.ctx_val ]
	end
}

puts tbl.to_s
