#!/usr/bin/env ruby


## Note, you may need to change this, depending on the install path of your 
## metasploit instance
require '/opt/metasploit-3.5.0/apps/pro/engine/lib/pro/client'

pro = Pro::Client.new() ## this will connect to the rpc service running on localhost:50505 

pro.call('db.add_workspace', "default") ## create a workspace
pro.call('db.set_workspace', "default") ## set that workspace

conf = {
        'workspace' => "default",
        'username'  => "rpc",
	"ips" => ['10.0.0.0/24'], 
        'DS_BLACKLIST_HOSTS' =>  "10.0.0.1 10.0.0.2",
        'DS_PORTSCAN_SPEED' =>  "3",
        'DS_PORTS_EXTRA' =>  "",
        'DS_PORTS_BLACKLIST' =>  "",
        'DS_PORTS_CUSTOM' =>  "",
        'DS_PORTSCAN_TIMEOUT' =>  "5",
        'DS_UDP_PROBES' =>  "true",
        'DS_IDENTIFY_SERVICES' => "true",
        'DS_SMBUser'   => "",
        'DS_SMBPass'   =>  "",
        'DS_SMBDomain' => "",
        'DS_DRY_RUN' =>  "false",
        'DS_SINGLE_SCAN' => "false",
        'DS_FAST_DETECT' => "false",
    	'DS_CustomNmap' => "--reason"
}

puts "starting discover task"
ret = pro.start_discover(conf)

task_id = ret['task_id']
puts "started discover task " + task_id

pro.task_wait(ret['task_id'])
puts "done!"
