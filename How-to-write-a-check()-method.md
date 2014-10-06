In Metasploit, exploits and auxiliary modules support the check command that allows the user to be able to determine the vulnerable state before using the module. This feature is handy for those who need to verify the vulnerability without actually popping a shell, and used to quickly identify all vulnerable, or possibly exploitable machines on the network.

Although vulnerability checks aren't the focus of Metasploit because it isn't a vulnerability scanner like Nexpose, we do actually encourage people to implement the check() method anyway to add more value to the module. If you do write one, make sure to keep these guidelines in mind:

## Check Method Output

Modules messages are important to the user, because that helps to keep them informed about what the module is doing, and sometimes it even allows them to debug problems by themselves. However, you do also want to keep your messages in verbose mode because it becomes really noisy if the check is used against multiple targets. Ideally, you only should be using these print methods:

| Method | Description |
| ------ | ----------- |
| **vprint_line()** | verbose version of print_line |
| **vprint_status()** | verbose version of print_status that begins with "[*]" |
| **vprint_error()** | verbose version of print_error that begins with "[x]" |
| **vprint_warning()** | verbose version of print_warning that begins with "[!]", in yellow |
| **vprint_debug()** | verbose versino of print_debug that begins with "[!]", in blue |


Note: You shouldn't be printing if a target is vulnerable or not, as this is automatically handled by the framework when your method returns a check code.

## Check Codes

Once you have determined the vulnerable state, you should return a check code. Check codes are constants defined in Msf::Exploit::CheckCode, and these are the ones you can use:

| Checkcode | Description |
| --------- | ----------- |
| **Exploit::CheckCode::Unknown** | Used if the module fails to retrieve enough information from the target machine, such as due to a timeout. |
| **Exploit::CheckCode::Safe** | Used if the check fails to trigger the vulnerability, or even detect the service. |
| **Exploit::CheckCode::Detected** | The target is running the service in question, but the check fails to determine whether the target is vulnerable or not. |
| **Exploit::CheckCode::Appears** | This is used if the vulnerability is determined based on passive reconnaissance. For example: version, banner grabbing, or simply having the resource that's known to be vulnearble. |
| **Exploit::CheckCode::Vulnerable** | Only used if the check is able to actually take advantage of the bug, and obtain some sort of hard evidence. For example: for a command execution type bug, get a command output from the target system. For a directory traversal, read a file from the target, etc. Since this level of check is pretty aggressive in nature, you should not try to DoS the host as a way to prove the vulnerability. |
| **Exploit::CheckCode::Unsupported** | The exploit does not support the check method. If this is the case, then you don't really have to add the check method. |


## Example

Here's an abstract example of how a Metasploit check might be written:

```ruby
#
# Returns a check code that indicates the vulnerable state on an app running on OS X
#
def check
  if exec_cmd_via_http("id") =~ /uid=\d+\(.+\)/
    # Found the correct ID output, good indicating our command executed
    return Exploit::CheckCode::Vulnerable
  end

  http_body = get_http_body
  if http_body
    if http_body =~ /Something CMS v1\.0/
      # We are able to find the version thefore more precise about the vuln state
      return Exploit::CheckCode::Appears
    elsif http_body =~ /Something CMS/
      # All we can tell the vulnerable app is running, but no more info to
      # determine the vuln
      return Exploit::CheckCode::Detected
    end
  else
    vprint_error("Unable to determine due to a HTTP connection timeout")
    return Exploit::CheckCode::Unknown
  end

  Exploit::CheckCode::Safe
end
```

Note: If you are writing an auxiliary module with the ```Msf::Auxiliary::Scanner``` mixin, you should declare your check method like this:

```ruby
def check_host(ip)
  # Do your thing
end
```