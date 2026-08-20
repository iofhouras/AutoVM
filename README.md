<div align="center">

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/assets/hero-dark.svg">
  <source media="(prefers-color-scheme: light)" srcset="docs/assets/hero-light.svg">
  <img alt="AutoVM — autonomously creates a virtual machine of your choosing" src="docs/assets/hero-light.svg" width="100%">
</picture>

<br>

<p>
  <a href="https://github.com/iofhouras/AutoVM/actions/workflows/build.yml"><img alt="build" src="https://github.com/iofhouras/AutoVM/actions/workflows/build.yml/badge.svg"></a>
  <a href="tests/Invoke-Tests.ps1"><img alt="65 tests passing" src="https://img.shields.io/badge/tests-65%20passing-3fb950?labelColor=1b1f24"></a>
  <a href="#what-you-need"><img alt="Windows 10 and 11" src="https://img.shields.io/badge/Windows-10%20%7C%2011-2a78d6?labelColor=1b1f24"></a>
  <a href="src/AutoVM"><img alt="PowerShell 5.1 and 7" src="https://img.shields.io/badge/PowerShell-5.1%20%7C%207-2a78d6?labelColor=1b1f24"></a>
  <a href="LICENSE"><img alt="MIT licence" src="https://img.shields.io/badge/licence-MIT-8b949e?labelColor=1b1f24"></a>
</p>

<h3><a href="https://iofhouras.github.io/AutoVM/">🌐&nbsp; autovm website &nbsp;— &nbsp;download and install it here</a></h3>

<p>
  <b><a href="https://github.com/iofhouras/AutoVM/releases/latest/download/AutoVM-Setup.exe">Direct download</a></b>
  &nbsp;·&nbsp; <a href="#how-it-works">How it works</a>
  &nbsp;·&nbsp; <a href="#every-screen">See every screen</a>
  &nbsp;·&nbsp; <a href="#what-it-decides-for-you">What it decides for you</a>
  &nbsp;·&nbsp; <a href="#use-it-from-a-script">Use it from a script</a>
</p>

</div>

---

You install AutoVM, start it, and type the login and password you want inside your new Linux
machine. That is your whole job.

AutoVM does the rest: it measures the computer it is running on, sizes a guest that will actually
run well there, installs the hypervisor, downloads a system image and checks it against the
publisher's own checksum, drives the installation without asking you a single installer question,
proves the account works by signing into it, takes a restore point, and leaves a control panel on
your desktop.

## Get it

### → [**autovm website**](https://iofhouras.github.io/AutoVM/)

The website is the place to send anyone who just wants the application. It has the download, the
requirements, screenshots of every screen and the answers to the usual questions.

Or go straight there:

**1 · Download** — [`AutoVM-Setup.exe`](https://github.com/iofhouras/AutoVM/releases/latest/download/AutoVM-Setup.exe)

**2 · Install** — run it. It needs administrator rights, because virtualization software installs
a driver.

**3 · Create** — start AutoVM, choose **Kali Linux Virtual Machine**, type the username and
password you want inside it, and press **Create VM Now!**

> [!NOTE]
> No release published yet? Every push also builds an installer — take it from the newest green run
> under [Actions][actions] → *Artifacts*.

### What you need

| | |
| :-- | :-- |
| **Windows** | 10 or 11, 64-bit |
| **Rights** | Administrator |
| **Memory** | 6 GB or more |
| **Disk** | ~45 GB free on any fixed volume |
| **Firmware** | Hardware virtualization (Intel VT-x / AMD-V) enabled |
| **Time** | 30–90 minutes, mostly unattended |

AutoVM checks every one of these on its second screen and tells you how to fix anything that is
missing — before it changes a thing.

## How it works

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/assets/flow-dark.svg">
  <source media="(prefers-color-scheme: light)" srcset="docs/assets/flow-light.svg">
  <img alt="Six screens for you, seven phases for AutoVM" src="docs/assets/flow-light.svg" width="100%">
</picture>

Six screens is what you see. Seven phases is what happens underneath, and each one has to *prove*
it worked before the next begins — the hypervisor by reporting its version, the image by matching
a checksum, the account by signing in, the restore point by appearing in the snapshot list. A
phase that cannot prove it stops the run and says so.

Every phase also records its outcome, so if you close the window, lose power, or Windows reboots
for an update, starting AutoVM again picks up where it stopped instead of doing it all over.

## Every screen

<details open>
<summary><b>Create</b> — the whole thing on one screen</summary>
<br>

<img alt="The create screen: pick Kali Linux, type a username and password, press Create VM Now!" src="docs/assets/screen-create.svg" width="100%">

Pick a system, type the login you want, press the button. The bar along the bottom tells you what
AutoVM has decided for this particular computer before you commit to anything, and the device check
runs quietly in the background while you type.

Type a login with **capitals** if you want one — which is harder than it looks. The Linux installer
only accepts lowercase account names and silently waits at a prompt when it gets anything else, the
usual reason an unattended install appears to hang forever. AutoVM creates the account in lowercase,
renames it once it exists, moves the home directory, repairs ownership, and then proves the result
by signing in as the name you actually asked for.

</details>

<details>
<summary><b>Building</b> — leave it running</summary>
<br>

<img alt="The build screen, with progress and a live log" src="docs/assets/screen-building.svg" width="100%">

Long quiet stretches are normal: the package upgrade inside the installer is most of the wait. The
full log is written to `C:\ProgramData\AutoVM\logs` as it goes, and your password never appears in
it. Closing the window costs the current step, not the run.

</details>

<details>
<summary><b>Ready</b> — what you are left with</summary>
<br>

<img alt="The finished screen, with the handover notes" src="docs/assets/screen-ready.svg" width="100%">

Plain language, no jargon: how to start it, exactly how to sign in, how to undo everything, and the
one security condition attached to your password.

</details>

<details>
<summary><b>My machines</b> — power, state and hardware</summary>
<br>

<img alt="The management screen: state, hardware and power controls" src="docs/assets/screen-manage.svg" width="100%">

AutoVM does not disappear once the machine exists — it becomes the console for it. Start it in a
window or in the background, shut it down cleanly, freeze its state, or force it off when it stops
responding.

</details>

<details>
<summary><b>Settings</b> — and the ones AutoVM refuses</summary>
<br>

<img alt="The settings tab: memory, processors, video memory and shared clipboard" src="docs/assets/screen-manage-settings.svg" width="100%">

Memory, processors, video memory and the shared clipboard, editable while the machine is shut down
and validated against your PC before they are applied — the same half-the-host ceiling that governs
a new build governs a later change.

Restore points and shared folders live on the next two tabs, along with export to a single `.ova`
file and deleting the machine (which asks you to type its name).

</details>

## What it decides for you

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/assets/sizing-dark.svg">
  <source media="(prefers-color-scheme: light)" srcset="docs/assets/sizing-light.svg">
  <img alt="Guest memory by host memory: rises with the device, then flattens at the 8192 MB cap" src="docs/assets/sizing-light.svg" width="100%">
</picture>

Sizing is arithmetic over the device, not a fixed template:

| What | Rule |
| :-- | :-- |
| **Memory** | 40 % of the host, rounded down to a 512 MB step — never more than half, never above 8192 MB, never below what the guest needs |
| **Processors** | Half the logical cores, capped at 4 |
| **Disk** | The guest's preferred size, trimmed to fit the roomiest fixed volume with 15 GB left for Windows |
| **Where** | That volume — not blindly `C:` |
| **Packages** | Under 12 GB of memory gets the light desktop set and no audio device |

## What it will not do

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/assets/safety-dark.svg">
  <source media="(prefers-color-scheme: light)" srcset="docs/assets/safety-light.svg">
  <img alt="What AutoVM changes with your say-so, and what it never touches" src="docs/assets/safety-light.svg" width="100%">
</picture>

> [!IMPORTANT]
> Your machine gets **outbound networking only**. Nothing on your network can reach into the
> guest, which is why a short password is acceptable inside it. If you ever switch the machine to
> bridged networking or forward a port into it, change the password first.

Removing virtual machines you already have is **off** unless you turn it on *and* type `DESTROY`.
Even then, WSL distribution disks, recovery images, `Windows.old` and any mounted disk are listed
as protected and kept.

## After the build

<table>
<tr>
<td width="52%" valign="top">

<img alt="The AutoVM Control Center" src="docs/assets/control-center.svg" width="100%">

</td>
<td width="48%" valign="top">

<p>A shortcut also lands on your desktop, for starting the machine without opening AutoVM at all.
From it you can:</p>
<ul>
  <li><b>Start</b> the machine in a window or headless</li>
  <li><b>Shut down</b> cleanly, or save its state</li>
  <li>Open <b>VirtualBox Manager</b> for anything advanced</li>
  <li><b>Restore to first-boot state</b> — back to the moment the build finished, discarding
      everything saved inside since</li>
</ul>
<p>The login is printed along the bottom, capitals and all, because that is the thing people
forget.</p>

</td>
</tr>
</table>

## Use it from a script

The wizard is one caller. The engine is a PowerShell module you can drive yourself.

```powershell
Import-Module 'C:\Program Files\AutoVM\AutoVM\AutoVM.psd1'

$password = Read-Host 'password' -AsSecureString

# See what this device would get. Changes nothing.
Invoke-AutoVMBuild -UserName analyst -Password $password -WhatIfPlanOnly

# Build it.
Invoke-AutoVMBuild -UserName analyst -Password $password -GuestId kali
```

Or the console front end, which prompts for the password and prints a summary:

```powershell
& 'C:\Program Files\AutoVM\AutoVM.Console.ps1' -UserName analyst -GuestId debian
```

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/assets/architecture-dark.svg">
  <source media="(prefers-color-scheme: light)" srcset="docs/assets/architecture-light.svg">
  <img alt="Launcher, wizard, engine and the two external commands it runs" src="docs/assets/architecture-light.svg" width="100%">
</picture>

## Systems you can build

| Id | System | Installs in | Package set |
| :-- | :-- | :-- | :-- |
| `kali` | Kali Linux | ~60 min | `kali-linux-core` + Xfce, or `kali-linux-default` |
| `debian` | Debian 13 | ~30 min | `task-xfce-desktop`, or `task-gnome-desktop` |

Both come from the publisher's own netinstall image over the publisher's own mirror. Adding
another is a JSON entry in [`guests.json`](src/AutoVM/Templates/guests.json) — no code change,
as long as it uses a Debian-style installer.

## When something goes wrong

<details>
<summary>Common stops, and what they mean</summary>
<br>

| What you see | What it means | What to do |
| :-- | :-- | :-- |
| "Hardware virtualization enabled" is red | VT-x / AMD-V is off in firmware | Reboot into BIOS/UEFI setup (often <kbd>F1</kbd>, <kbd>F2</kbd>, or the Novo button), enable it under Security, then choose **Check again** |
| "Free disk space" is red | No fixed volume has room | Free space, or let AutoVM use another drive — it picks the roomiest one automatically |
| VirtualBox fails to install | Device-management policy is blocking a kernel driver | AutoVM reports it rather than working around it. Ask whoever manages the device to allow Oracle VirtualBox |
| The build stops on a checksum | The download is corrupt or was tampered with | AutoVM deletes it and stops. Run it again; a second failure means the mirror is the problem |
| The install seems stuck | Usually the package upgrade, which is quiet for 20–30 minutes | Let it run. If it hits the deadline, AutoVM captures a picture of what the machine is showing |
| "Login incorrect" in the guest | Linux logins are case-sensitive | Type the login exactly as you entered it — including capitals |

Every run writes a full log to `C:\ProgramData\AutoVM\logs`, and the final screen names the step
that stopped. Starting AutoVM again continues from the last completed step.

</details>

## Build it yourself

```powershell
./build/Build-Installer.ps1 -Version 1.0.0    # -> dist/AutoVM-Setup-1.0.0.exe
./build/Build-Installer.ps1 -SkipInstaller    # -> dist/staging, a runnable copy
./tests/Invoke-Tests.ps1                      # 65 tests, Windows or Linux
```

The installer needs [Inno Setup 6][inno] on Windows. The tests need nothing at all.

<details>
<summary>Repository layout</summary>
<br>

```
src/AutoVM/            the engine — PowerShell module, seven phases, pure planning logic
src/AutoVM.App/        the wizard — WPF window and its host script, plus a console front end
src/AutoVM.Launcher/   a small C# executable so the app has an icon and one elevation prompt
build/                 launcher compilation and the Inno Setup installer definition
tests/                 dependency-free test suite
site/                  the website, deployed to GitHub Pages by .github/workflows/pages.yml
docs/agent-directive/  the 50-page design document this implementation follows
docs/assets/           the artwork on this page and the website, and the script that generates it
```

</details>

## Where it stands

| | |
| :-- | :-- |
| Engine tests | **65 passing** — sizing, gates, credentials, answer-file generation, deletion safety, secret redaction, the resume ledger |
| Script and window parsing | Every `.ps1` / `.psm1` / `.psd1` and the XAML, in CI |
| Module load | PowerShell 7 on Linux, Windows PowerShell 5.1 on Windows, in CI |
| Installer build | Compiled and uploaded on `windows-latest`, every push |
| **End-to-end build on real hardware** | **Not yet run** |

> [!WARNING]
> The parts that cannot be unit-tested — the VirtualBox calls, the unattended install, the desktop
> shortcut — are written against [the design document](docs/agent-directive/) but have not been
> executed against a live Windows host from this repository. Treat your first run as the smoke
> test, and send us `C:\ProgramData\AutoVM\logs` if it stops.

## Documentation

- **[The AutoVM website](https://iofhouras.github.io/AutoVM/)** — the page to send anyone who just
  wants to download and use the application.
- **[Agent Directive rev 2.0](docs/agent-directive/KaliVMAgentDirective-v2.pdf)** — the 50-page
  design document behind the engine: phases, gates, failure playbook, and the reasoning behind
  each decision.
- **[Application architecture](docs/APPLICATION.md)** — how the wizard, the engine and the
  installer fit together, and how to add a guest.
- **[End-user notes](docs/INSTALL.txt)** — what ships as the installed README.

## Licence

[MIT](LICENSE). AutoVM installs and drives third-party software under its own terms — VirtualBox
is GPLv3, and guest images are downloaded from their publishers rather than redistributed here.

[releases]: https://github.com/iofhouras/AutoVM/releases
[actions]: https://github.com/iofhouras/AutoVM/actions
[inno]: https://jrsoftware.org/isinfo.php
