## What this changes

<!-- One or two sentences. What is different after this merges? -->

## Why

<!-- The problem being solved. Link an issue if there is one. -->

## How it was verified

<!-- Tick what you actually ran, and say what you could not. -->

- [ ] `./tests/Invoke-Tests.ps1` passes
- [ ] New or changed logic that can be tested without a hypervisor has a test
- [ ] Built the installer (`./build/Build-Installer.ps1 -SkipInstaller`)
- [ ] Ran a real build on a Windows host — if not, say so here rather than leaving it implied

## Things worth a second look

<!-- Anything you are unsure about, or that a reviewer should push back on. -->

---

<!--
A note on the two rules this project does not bend:

  * Nothing gets deleted without the user opting in and typing DESTROY, and the protected
    classes stay protected.
  * Host security features are never disabled to make a guest faster. A block is reported,
    not worked around.

A change that touches either needs to say so explicitly above.
-->
