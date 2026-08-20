# Contributing

Thanks for looking. AutoVM installs software and creates disks on other people's computers, so
the bar for changes is a little higher than usual — the notes below are mostly about that.

## Getting set up

```powershell
./tests/Invoke-Tests.ps1                      # 65 tests, no dependencies, Windows or Linux
./build/Build-Installer.ps1 -SkipInstaller    # a runnable copy in dist/staging
./build/Build-Installer.ps1 -Version 1.0.0    # the installer, needs Inno Setup 6
```

The test suite deliberately has no dependencies. It runs on PowerShell 5.1 and 7, on Windows and
Linux, with nothing to install first — so there is never an excuse for not running it.

## Where things live

| | |
| :-- | :-- |
| `src/AutoVM/Private/` | The engine, loaded in numeric order. Pure logic first, side effects last. |
| `src/AutoVM/Public/` | `Invoke-AutoVMBuild` — phase orchestration and nothing else. |
| `src/AutoVM.App/` | The wizard. It calls the engine; it never reimplements it. |
| `docs/assets/` | The README artwork. Edit `build-assets.py`, never the generated SVGs. |

## Two rules that do not bend

**Nothing is deleted without consent.** Removal is opt-in, requires the literal string `DESTROY`
compared case-sensitively, and the protected classes — WSL disks, recovery images, `Windows.old`,
mounted disks, removable media — stay protected. A change that widens what can be deleted needs a
very good reason and a test.

**Host security features are never disabled.** If virtualization-based security, Memory Integrity
or driver signing gets in the way, AutoVM reports it as an environment problem and stops. It does
not disable protections, test-sign drivers, or work around policy. Making the guest faster is not
worth weakening the machine it runs on.

## Writing changes

**Keep logic pure where you can.** Sizing, gate evaluation, credential validation, answer-file
generation and path classification are all pure functions over data. That is why they can be
tested in two seconds on a machine with no hypervisor. New logic in that shape belongs in the
same place.

**Test what you can, and say what you cannot.** The VirtualBox calls and the unattended install
need real hardware. If you change them, run a real build and say so in the pull request — and if
you could not, say that instead. An untested claim is worse than an admitted gap.

**Never log a secret.** Anything sensitive goes through `Register-AutoVMSecret` so it is masked
before it reaches disk. The one file that must contain the guest password is written to a
restricted directory and shredded in a `finally` block. Keep it that way.

**Match the surrounding style.** Full cmdlet names, `[CmdletBinding()]`, comment-based help on
anything exported, and comments that explain *why* rather than restating the code.

## Adding a guest system

Most of the time this is a JSON entry in
[`src/AutoVM/Templates/guests.json`](src/AutoVM/Templates/guests.json) — no code change, provided
the distribution uses a Debian-style installer and publishes a `SHA256SUMS` beside its images.
[`docs/APPLICATION.md`](docs/APPLICATION.md) has the field list.

A distribution with a different answer-file format needs a new `family` and a generator beside
`08-Preseed.ps1`. Please open an issue before starting one of those.

## Regenerating the artwork

```bash
python3 docs/assets/build-assets.py
```

Every figure is generated twice, once per GitHub canvas colour. Do not hand-edit the SVGs — the
next run will overwrite them.
