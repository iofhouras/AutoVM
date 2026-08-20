# Security

## Reporting a problem

Please report privately through
[GitHub's security advisories](https://github.com/iofhouras/AutoVM/security/advisories/new)
rather than opening a public issue. Include what you found, how to reproduce it, and what an
attacker gains.

## What AutoVM does with your password

The guest account password is the one piece of user data AutoVM handles carefully, because the
Linux installer's answer file format requires it in clear text.

1. The wizard holds it as a `SecureString`.
2. It crosses into the worker thread as a `SecureString` — same process, never serialised.
3. It is registered as a secret, so every log line is scanned and masked before it is written.
4. It is turned into text exactly twice: writing the answer file, and proving the login works.
5. The answer file is written to a directory restricted to SYSTEM and Administrators, then
   overwritten with random bytes and deleted in a `finally` block.
6. Nothing else — no build report, no resume ledger, no handover note — ever contains it.

If you find a path where it survives somewhere it should not, that is a security report.

## The guest's network posture

A machine built by AutoVM gets NAT only: it can reach out, nothing can reach in. There is no port
forwarding, no bridged adapter and no SSH server. That is what makes a short guest password
acceptable, and the finished screen says so in plain words.

**If you move the machine onto a bridged network or forward a port into it, change the password
first.**

## What AutoVM refuses to do

These are not settings. Nothing in the codebase can do them:

- Disable virtualization-based security, Memory Integrity, or the Virtual Machine Platform
- Disable driver signature enforcement, or test-sign a driver
- Modify host firewall rules
- Delete WSL distribution disks, recovery images, `Windows.old`, mounted disks, or anything on
  removable or network media
- Install a system image whose checksum does not match the one its publisher published

If policy on a managed device blocks the hypervisor, AutoVM reports it as an environment problem
and stops. Working around it would weaken the machine the user asked to be careful with.

## Supply chain

Guest images are downloaded from their publisher, over HTTPS, with the filename resolved from the
publisher's current directory listing rather than hardcoded. Every download is verified against
the publisher's own `SHA256SUMS` before it is attached to anything, and a mismatch deletes the
file and stops the build. AutoVM does not redistribute images.

VirtualBox and 7-Zip are installed through `winget` from their published package identifiers. The
VirtualBox Extension Pack is **not** installed — it carries a licence that is free only for
personal and evaluation use, and nothing in this build needs it.

## Supported versions

Fixes go onto the latest release. The project is young enough that there are no maintenance
branches.
