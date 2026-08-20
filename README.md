# AutoVM

Autonomously creates a virtual machine of your choosing, from one click.

AutoVM is a Windows desktop application. You install it, start it, and type the login and
password you want inside your new Linux machine. It works out everything else: it profiles the
computer it is running on, sizes a guest that will actually run well there, installs the
hypervisor, downloads and verifies a system image, drives the installation without asking you a
single installer question, proves the account works, takes a restore point, and leaves a control
panel on your desktop.

<!-- markdownlint-disable-next-line -->
> **Status.** The engine is complete and unit-tested, and the installer builds in CI. The
> end-to-end build has not yet been run against real hardware — see [Verification](#verification).

## Getting it

Download `AutoVM-Setup-<version>.exe` from the [latest release][releases], run it, and start
AutoVM from the Start menu. That is the whole install.

Every push also produces an installer as a build artifact under the repository's
[Actions][actions] tab.

[releases]: https://github.com/iofhouras/AutoVM/releases
[actions]: https://github.com/iofhouras/AutoVM/actions

### What you need

| | |
| --- | --- |
| Windows | 10 or 11, 64-bit |
| Rights | Administrator — virtualization software installs a driver |
| Memory | 6 GB or more |
| Disk | ~45 GB free on any fixed volume |
| Firmware | Hardware virtualization (Intel VT-x / AMD-V) enabled |
| Time | 30–90 minutes, mostly unattended |

AutoVM checks all of this on its second screen and tells you exactly how to fix anything that is
missing, rather than failing halfway through.

## What it does

Six screens, seven phases.

```
Welcome  →  This device  →  Your account  →  Review  →  Building  →  Ready
               │                 │             │           │
               │                 │             │           └─ install, verify, snapshot, shortcut
               │                 │             └─ nothing has changed yet; last chance to stop
               │                 └─ the login and password you want in the guest
               └─ profile the machine, evaluate every gate, size the guest
```

**It configures itself to the device.** Guest memory is 40 % of host memory, rounded to a 512 MB
step and never above half; vCPUs are half the logical cores, capped at four; the disk is capped by
free space on the roomiest fixed volume with a 15 GB margin left for the host; a small machine
gets the light desktop package set and no audio device. A device with 8 GB and 8 cores gets a
3072 MB, 4-vCPU guest; the same 8 GB with 4 cores gets 2 vCPUs, and 64 GB gets the 8192 MB cap.

**It uses the credentials you typed.** Including capitals — which is harder than it sounds. The
Debian installer validates account names against a lowercase-only pattern and quietly falls back
to an interactive prompt when a value is rejected, which turns an unattended install into one that
waits forever. AutoVM creates the account in lowercase, renames it once it exists, moves the home
directory, repairs ownership, and then proves the result by signing in.

**It verifies what it installs.** Image filenames are read from the publisher's current directory
listing rather than hardcoded, and every download is checked against the publisher's own SHA-256
before it is attached to anything. A mismatch deletes the file and stops the build.

**It is safe by default.** It never touches the machines you already have unless you turn that on
and type `DESTROY`; WSL disks, recovery images and mounted disks are excluded from removal
entirely. It never edits your firewall, and it never disables Windows security features to make
the guest faster — it reports the trade-off and lets you decide.

**It can be interrupted.** Every phase records its outcome, so closing the window or losing power
costs the current step, not the run.

## Using it from a script

The engine is a PowerShell module; the wizard is one caller.

```powershell
Import-Module 'C:\Program Files\AutoVM\AutoVM\AutoVM.psd1'

# See what this device would get, without changing anything
$password = Read-Host 'password' -AsSecureString
Invoke-AutoVMBuild -UserName analyst -Password $password -WhatIfPlanOnly

# Build it
Invoke-AutoVMBuild -UserName analyst -Password $password -GuestId kali
```

Or the console front end, which prompts for the password and prints a summary:

```powershell
& 'C:\Program Files\AutoVM\AutoVM.Console.ps1' -UserName analyst -GuestId debian
```

## Guests

| Id | System | Installs in | Package set |
| --- | --- | --- | --- |
| `kali` | Kali Linux | ~60 min | `kali-linux-core` + Xfce, or `kali-linux-default` |
| `debian` | Debian 13 | ~30 min | `task-xfce-desktop`, or `task-gnome-desktop` |

Both are installed from the publisher's netinstall image, over the publisher's mirror. Adding a
guest means adding an entry to `src/AutoVM/Templates/guests.json` — no code change, provided the
system uses a Debian-style installer.

## Repository layout

```
src/AutoVM/            the engine: a PowerShell module, phases and pure planning logic
src/AutoVM.App/        the wizard: WPF window plus its host script, and a console front end
src/AutoVM.Launcher/   a small C# executable so the app has an icon and one elevation prompt
build/                 launcher compilation and the Inno Setup installer definition
tests/                 dependency-free test suite for the engine
docs/agent-directive/  the design document this implementation follows
```

## Building from source

On Windows, with [Inno Setup 6][inno] installed:

```powershell
./build/Build-Installer.ps1 -Version 1.0.0     # -> dist/AutoVM-Setup-1.0.0.exe
./build/Build-Installer.ps1 -SkipInstaller     # -> dist/staging, a runnable copy
```

Run the tests anywhere PowerShell runs, Windows or Linux:

```powershell
./tests/Invoke-Tests.ps1
```

[inno]: https://jrsoftware.org/isinfo.php

## Verification

What has been verified, and what has not:

| | |
| --- | --- |
| Engine unit tests | 65 tests, passing — sizing, gates, credentials, answer-file generation, deletion safety, secret redaction, the resume ledger |
| Script and window parsing | Every `.ps1`/`.psm1`/`.psd1` and the XAML, in CI |
| Module load | PowerShell 7 on Linux, and Windows PowerShell 5.1 on Windows, in CI |
| Installer build | Compiled in CI on `windows-latest` |
| **End-to-end build on real hardware** | **Not yet run.** Needs a Windows host with virtualization enabled, ~45 GB free and roughly an hour |

The parts that cannot be unit-tested — the VirtualBox calls, the unattended install, the desktop
shortcut — are written against [the design document](docs/agent-directive/), which documents each
command and its expected output, but they have not been executed against a live host from this
repository.

## Documentation

- [Agent Directive — Autonomous Kali Linux VM Provisioning on Windows](docs/agent-directive/KaliVMAgentDirective-v2.pdf)
  (rev 2.0) — the 50-page design document behind the engine: phases, gates, failure playbook and
  the reasoning behind each decision.
- [Application architecture](docs/APPLICATION.md) — how the wizard, the engine and the installer
  fit together.
- [End-user notes](docs/INSTALL.txt) — what ships as the installed README.

## Licence

[MIT](LICENSE). AutoVM installs and drives third-party software under its own terms — VirtualBox
is GPLv3, and guest images are downloaded from their publishers rather than redistributed here.
