# -*- coding: binary -*-
require 'msf/ui/console/command_dispatcher'

module Msf
module Ui
module Console

###
#
# Module-specific command dispatcher.
#
###
module ModuleCommandDispatcher

  include Msf::Ui::Console::CommandDispatcher

  def commands
    {
      "pry"    => "Open a Pry session on the current module",
      "reload" => "Reload the current module from disk",
      "check"  => "Check to see if a target is vulnerable"
    }
  end

  #
  # The active driver module, if any.
  #
  def mod
    return driver.active_module
  end

  #
  # Sets the active driver module.
  #
  def mod=(m)
    self.driver.active_module = m
  end

  def check_progress
    return 0 unless @range_done and @range_count
    pct = (@range_done / @range_count.to_f) * 100
  end

  def check_show_progress
    pct = check_progress
    if(pct >= (@range_percent + @show_percent))
      @range_percent = @range_percent + @show_percent
      tdlen = @range_count.to_s.length
      print_status("Checked #{"%.#{tdlen}d" % @range_done} of #{@range_count} hosts (#{"%.3d" % pct.to_i}% complete)")
    end
  end

  def check_multiple(hosts)
    @show_progress = framework.datastore['ShowProgress'] || mod.datastore['ShowProgress'] || false
    @show_percent  = ( framework.datastore['ShowProgressPercent'] || mod.datastore['ShowProgressPercent'] ).to_i

    @range_count   = hosts.length || 0
    @range_done    = 0
    @range_percent = 0

    threads_max = (framework.datastore['THREADS'] || mod.datastore['THREADS'] || nil).to_i
    @tl = []


    if Rex::Compat.is_windows
      if threads_max == 0 or threads_max > 16
        vprint_warning("Thread count has been adjusted to 16")
        threads_max = 16
      end
    end

    if Rex::Compat.is_cygwin
      if threads_max == 0 or threads_max > 200
        vprint_warning("Thread count has been adjusted to 200")
        threads_max = 200
      end
    end

    while (true)
      while (@tl.length < threads_max)
        ip = hosts.next_ip
        break unless ip

        @tl << framework.threads.spawn("CheckHost-#{ip}", false, ip.dup) do |tip|
          mod.datastore['RHOST'] = tip
          check_simple
        end
      end

      break if @tl.length == 0

      tla = @tl.length
      @tl.first.join
      @tl.delete_if { |t| not t.alive? }
      tlb = @tl.length

      @range_done += (tla - tlb)
      check_show_progress if @show_progress
    end
  end

  #
  # Checks to see if a target is vulnerable.
  #
  def cmd_check(*args)
    defanged?

    ip_range_arg = args.shift || framework.datastore['RHOSTS'] || mod.datastore['RHOSTS'] || ''
    hosts = Rex::Socket::RangeWalker.new(ip_range_arg)

    begin
      if hosts.ranges.blank?
        # Check a single rhost
        check_simple
      else
        last_rhost_opt = mod.rhost
        last_rhosts_opt = mod.datastore['RHOSTS']
        mod.datastore['RHOSTS'] = ip_range_arg
        begin
          check_multiple(hosts)
        ensure
          # Restore the original rhost if set
          mod.datastore['RHOST'] = last_rhost_opt
          mod.datastore['RHOSTS'] = last_rhosts_opt
          mod.cleanup
        end
      end
    rescue ::Interrupt
      print_status("Caught interrupt from the console...")
      return
    end
  end

  def check_simple
    rhost = mod.rhost
    rport = mod.rport

    begin
      code = mod.check_simple(
        'LocalInput'  => driver.input,
        'LocalOutput' => driver.output)
      if (code and code.kind_of?(Array) and code.length > 1)
        if (code == Msf::Exploit::CheckCode::Vulnerable)
          print_good("#{rhost}:#{rport} - #{code[1]}")
        else
          print_status("#{rhost}:#{rport} - #{code[1]}")
        end
      else
        print_error("#{rhost}:#{rport} - Check failed: The state could not be determined.")
      end
    rescue ::Rex::ConnectionError, ::Rex::ConnectionProxyError, ::Errno::ECONNRESET, ::Errno::EINTR, ::Rex::TimeoutError, ::Timeout::Error
    rescue ::NoMethodError, ::RuntimeError, ::ArgumentError, ::NameError
    rescue ::Exception => e
      if(e.class.to_s != 'Msf::OptionValidateError')
        print_error("Check failed: #{e.class} #{e}")
        print_error("Call stack:")
        e.backtrace.each do |line|
          break if line =~ /lib.msf.base.simple/
          print_error("  #{line}")
        end
      else
        print_error("#{rhost}:#{rport} - Check failed: #{e.class} #{e}")
      end
    end
  end

  def cmd_pry_help
    print_line "Usage: pry"
    print_line
    print_line "Open a pry session on the current module.  Be careful, you"
    print_line "can break things."
    print_line
  end

  def cmd_pry(*args)
    begin
      require 'pry'
    rescue LoadError
      print_error("Failed to load pry, try 'gem install pry'")
      return
    end
    mod.pry
  end

  #
  # Reloads the active module
  #
  def cmd_reload(*args)
    begin
      reload
    rescue
      log_error("Failed to reload: #{$!}")
    end
  end

  @@reload_opts =  Rex::Parser::Arguments.new(
    '-k' => [ false,  'Stop the current job before reloading.' ],
    '-h' => [ false,  'Help banner.' ])

  def cmd_reload_help
    print_line "Usage: reload [-k]"
    print_line
    print_line "Reloads the current module."
    print @@reload_opts.usage
  end

  #
  # Reload the current module, optionally stopping existing job
  #
  def reload(should_stop_job=false)
    if should_stop_job and mod.job_id
      print_status('Stopping existing job...')

      framework.jobs.stop_job(mod.job_id)
      mod.job_id = nil
    end

    print_status('Reloading module...')

    original_mod = self.mod
    reloaded_mod = framework.modules.reload_module(original_mod)

    unless reloaded_mod
      error = framework.modules.module_load_error_by_path[original_mod.file_path]

      print_error("Failed to reload module: #{error}")

      self.mod = original_mod
    else
      self.mod = reloaded_mod

      self.mod.init_ui(driver.input, driver.output)
    end

    reloaded_mod
  end

end


end end end

