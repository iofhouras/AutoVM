# AutoVM application architecture

How the pieces fit, why they are split that way, and where to change things.

## Layers

```
  AutoVM.exe                 C# launcher. Icon, single elevation prompt, starts the host.
      │
      ▼
  AutoVM.ps1                 WPF wizard. Six screens, no engine logic of its own.
      │  runspace + queue
      ▼
  AutoVM (module)            The engine. Seven phases, gates, planning, VirtualBox driver.
      │
      ▼
  VBoxManage / winget        The only external commands AutoVM runs.
```

The split matters in one direction: **the engine never talks to the user interface.** It emits
structured records to a progress sink; the wizard registers one, the console front end registers
none. That is what lets the same code path serve a wizard, a script and CI.

## The engine

`src/AutoVM/` is a PowerShell module. Files load in numeric order, private helpers first.

| File | Responsibility |
| --- | --- |
| `00-Logging.ps1` | Structured records, secret redaction, the progress sink |
| `01-Environment.ps1` | Working directory, elevation, secure-string handling, file shredding |
| `02-State.ps1` | The resume ledger — one record per phase, written before the next starts |
| `03-HostProfile.ps1` | Read-only device profile; volume selection |
| `04-Gates.ps1` | The pre-flight matrix and its verdict |
| `05-Plan.ps1` | Sizing arithmetic — pure, and the most heavily tested part |
| `06-Catalog.ps1` | Guest definitions, image name resolution, checksum extraction |
| `07-Credential.ps1` | Login and password validation, and the rename plan |
| `08-Preseed.ps1` | Installer answer file generation |
| `09-VirtualBox.ps1` | Every `VBoxManage` call the engine makes |
| `10-Image.ps1` | Resumable download and mandatory verification |
| `11-Teardown.ps1` | Optional removal, protected classes, the consent check |
| `12-Handover.ps1` | Control panel, shortcut, the plain-language summary |
| `Public/Invoke-AutoVMBuild.ps1` | Phase orchestration |

Anything that can be pure, is: `New-AutoVMPlan`, `Test-AutoVMGate`, `Test-AutoVMUserName`,
`New-AutoVMPreseed`, `Select-AutoVMIsoName`, `Test-AutoVMProtectedPath`. That is deliberate — it
is the difference between a test suite that runs on any machine in two seconds and one that needs
a hypervisor.

## Phases

Each phase declares what it needs, what it does, what it leaves behind, and how its success is
proved. The orchestrator records the outcome in `state.json` before moving on.

| Phase | Does | Proved by |
| --- | --- | --- |
| P1 | Profile the device, plan the guest, evaluate the gates | Gate verdict is not `Blocked` |
| P2 | Remove existing machines *(opt-in)* | Confirmation token, protected items kept |
| P3 | Install VirtualBox and 7-Zip | `VBoxManage --version` returns a version |
| P4 | Resolve, download and verify the image | Computed SHA-256 equals the published one |
| P5 | Create the machine, drive the unattended install | Guest reports its operating system |
| P6 | Verify the account, take the restore point | `id <user>` inside the guest; snapshot listed |
| P7 | Write the control panel and the shortcut | The shortcut exists on disk |

A phase that cannot prove its exit condition fails. It does not assume, and it does not continue.

## Threading in the wizard

WPF needs a single-threaded apartment and a responsive dispatcher; the build takes up to an hour.

```
UI thread                          worker runspace
─────────                          ───────────────
Start-Build ──────────────────────► Invoke-AutoVMBuild
                                          │
DispatcherTimer (220 ms)  ◄── queue ◄──── progress sink
   drains, appends to log,
   moves the progress bar
```

`ConcurrentQueue` is the only shared state. The worker never touches a control, the UI never
blocks on the engine, and closing the window stops the runspace after asking.

## Handling of the password

The password is the one piece of user data AutoVM must handle carefully, because the installer
format requires it in clear text.

1. The wizard holds it as the `PasswordBox`'s `SecureString`.
2. It crosses into the worker runspace as a `SecureString` — same process, no serialisation.
3. It is registered as a secret, so every log line is scanned and masked before it is written.
4. It is converted to text exactly twice: writing the answer file, and proving the login.
5. The answer file lives in a directory restricted to SYSTEM and Administrators, and is
   overwritten with random bytes and deleted in a `finally` block.
6. Nothing else — no report, no ledger, no handover note — ever contains it.

## Adding a guest

Add an object to `src/AutoVM/Templates/guests.json`:

```json
{
  "id": "mydistro",
  "name": "My Distro",
  "family": "debian-installer",
  "vboxOsType": "Debian_64",
  "isoBaseUrl": "https://example.org/current/",
  "isoPattern": "mydistro-[0-9.]+-amd64\\.iso",
  "checksumFile": "SHA256SUMS",
  "mirrorHostname": "deb.example.org",
  "mirrorDirectory": "/mydistro",
  "minimumRamMB": 2048,
  "minimumCpus": 1,
  "minimumDiskGB": 20,
  "preferredDiskGB": 50,
  "approximateIsoGB": 1.0,
  "estimatedMinutes": 35,
  "packages": { "light": ["task-xfce-desktop"], "full": ["task-gnome-desktop"] }
}
```

No code change is needed as long as the distribution uses a Debian-style installer and publishes
a `SHA256SUMS` beside its images. A distribution with a different answer-file format needs a new
`family` and a matching generator alongside `08-Preseed.ps1`.

## Build and release

`build/Build-Installer.ps1` does three things: compiles `Launcher.cs` with the .NET Framework
compiler that ships with Windows (so the installed application needs no runtime), stages the
application into `dist/staging`, and compiles that with Inno Setup into a single
`AutoVM-Setup-<version>.exe`.

CI runs the test suite on Linux, builds the installer on Windows, re-runs the tests there, loads
the engine under Windows PowerShell 5.1, and uploads the installer. Pushing a `v*` tag publishes
it as a release.

## What is not covered by tests

The VirtualBox calls, the unattended install and the shortcut creation need a real Windows host
with virtualization available. They are written against the [design document](agent-directive/),
which records each command and its expected output, but they have not been executed end-to-end
from this repository. Treat the first real run as a smoke test, and read
`C:\ProgramData\AutoVM\logs` when it stops.
