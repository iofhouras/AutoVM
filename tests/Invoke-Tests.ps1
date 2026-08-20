<#
    AutoVM test suite.

    Deliberately dependency-free: it runs anywhere PowerShell 5.1+ runs, on
    Windows or Linux, with nothing to install first. Everything covered here is
    pure logic - sizing, validation, parsing, redaction - which is exactly the
    part that must be right before the engine is ever pointed at a real machine.

    Usage:  pwsh -File tests/Invoke-Tests.ps1
    Exit code 0 when every test passes, 1 otherwise.
#>
[CmdletBinding()]
param([switch]$Detailed)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$env:AUTOVM_ROOT = Join-Path ([System.IO.Path]::GetTempPath()) ("autovm-tests-" + [guid]::NewGuid().ToString('N'))

Import-Module (Join-Path $root 'src/AutoVM/AutoVM.psd1') -Force

$script:Passed = 0
$script:Failed = 0
$script:Current = ''

function Describe-Group { param([string]$Name) Write-Host "`n$Name" -ForegroundColor Cyan; $script:Current = $Name }

function Test-Case {
    param([string]$Name, [scriptblock]$Body)
    try {
        & $Body
        $script:Passed++
        Write-Host "  PASS  $Name" -ForegroundColor Green
    } catch {
        $script:Failed++
        Write-Host "  FAIL  $Name" -ForegroundColor Red
        Write-Host "        $($_.Exception.Message)" -ForegroundColor DarkRed
        if ($Detailed) { Write-Host "        $($_.ScriptStackTrace)" -ForegroundColor DarkGray }
    }
}

function Assert-True { param($Condition, [string]$Because = 'expected a true value')
    if (-not $Condition) { throw $Because } }
function Assert-False { param($Condition, [string]$Because = 'expected a false value')
    if ($Condition) { throw $Because } }
function Assert-Equal { param($Expected, $Actual, [string]$Because)
    if ($Expected -ne $Actual) { throw ("{0}expected [{1}], got [{2}]" -f $(if ($Because) { "$Because - " } else { '' }), $Expected, $Actual) } }
function Assert-Match { param([string]$Pattern, [string]$Text, [string]$Because)
    if ($Text -notmatch $Pattern) { throw ("{0}text did not match /{1}/" -f $(if ($Because) { "$Because - " } else { '' }), $Pattern) } }
function Assert-NotMatch { param([string]$Pattern, [string]$Text, [string]$Because)
    if ($Text -match $Pattern) { throw ("{0}text unexpectedly matched /{1}/" -f $(if ($Because) { "$Because - " } else { '' }), $Pattern) } }
function Assert-MatchCase { param([string]$Pattern, [string]$Text, [string]$Because)
    if ($Text -cnotmatch $Pattern) { throw ("{0}text did not match /{1}/ case-sensitively" -f $(if ($Because) { "$Because - " } else { '' }), $Pattern) } }
function Assert-NotMatchCase { param([string]$Pattern, [string]$Text, [string]$Because)
    if ($Text -cmatch $Pattern) { throw ("{0}text unexpectedly matched /{1}/ case-sensitively" -f $(if ($Because) { "$Because - " } else { '' }), $Pattern) } }

# Reaches functions the module keeps internal, without exporting them for the sake of a test.
$script:Module = Get-Module AutoVM
function Invoke-InModule { param([scriptblock]$Body) & $script:Module $Body }
function Assert-Throws { param([scriptblock]$Body, [string]$Pattern)
    try { & $Body } catch { if ($Pattern -and $_.Exception.Message -notmatch $Pattern) { throw "threw, but message did not match /$Pattern/: $($_.Exception.Message)" }; return }
    throw 'expected an exception, none was thrown' }

function New-TestSecureString { param([string]$Text) ConvertTo-SecureString $Text -AsPlainText -Force }

function New-TestHostProfile {
    param([double]$RamGB = 8, [int]$Cores = 8, [double]$FreeGB = 200, [bool]$VT = $true,
        [string]$Slat = 'Extended Page Tables', [bool]$Hypervisor = $false, [bool]$Elevated = $true)
    [pscustomobject]@{
        ComputerModel = 'TEST'; OSCaption = 'Microsoft Windows 11 Home'; OSBuild = '10.0.26100.1'
        IsHomeSKU = $true; TotalRAM_GB = $RamGB; FreeRAM_GB = [math]::Round($RamGB / 2, 2)
        CPUName = 'Test CPU'; LogicalCores = $Cores; VTEnabled = $VT; SLAT = $Slat
        HypervisorPresent = $Hypervisor; VBSRunning = $(if ($Hypervisor) { 2 } else { 0 })
        HVCIRunning = $Hypervisor; WSLInstalled = $false; VMPlatform = 'Disabled'
        Volumes = @([pscustomobject]@{ Letter = 'C'; SizeGB = 476.0; FreeGB = $FreeGB; FreePct = 42.0 })
        VBoxInstalled = $false; VBoxVersion = ''; VMwareInstalled = $false
        IsElevated = $Elevated; PSVersion = '7.4.0'
    }
}

# ---------------------------------------------------------------- user names
Describe-Group 'Login name validation'

Test-Case 'accepts a simple lowercase name' {
    $r = Test-AutoVMUserName -UserName 'kali'
    Assert-True $r.IsValid
    Assert-False $r.RequiresRename
    Assert-Equal 'kali' $r.Normalised
}

Test-Case 'accepts a capitalised name and plans the rename' {
    $r = Test-AutoVMUserName -UserName 'Kali'
    Assert-True $r.IsValid 'a capitalised login must be accepted'
    Assert-True $r.RequiresRename 'the installer only takes lowercase, so a rename is required'
    Assert-Equal 'kali' $r.Normalised
    Assert-Match 'case-sensitive' $r.Reason
}

Test-Case 'rejects an empty name' {
    Assert-False (Test-AutoVMUserName -UserName '').IsValid
}

Test-Case 'rejects names starting with a digit' {
    Assert-False (Test-AutoVMUserName -UserName '1user').IsValid
}

Test-Case 'rejects names containing a space or shell metacharacter' {
    Assert-False (Test-AutoVMUserName -UserName 'my user').IsValid
    Assert-False (Test-AutoVMUserName -UserName 'user;rm').IsValid
    Assert-False (Test-AutoVMUserName -UserName 'user$(x)').IsValid
}

Test-Case 'rejects names longer than 32 characters' {
    Assert-False (Test-AutoVMUserName -UserName ('a' * 33)).IsValid
}

Test-Case 'rejects reserved system accounts, in any case' {
    Assert-False (Test-AutoVMUserName -UserName 'root').IsValid
    Assert-False (Test-AutoVMUserName -UserName 'Root').IsValid
    Assert-False (Test-AutoVMUserName -UserName 'www-data').IsValid
}

# ---------------------------------------------------------------- passwords
Describe-Group 'Password validation'

Test-Case 'rejects an empty password' {
    $r = Test-AutoVMPassword -Password ''
    Assert-False $r.IsValid
}

Test-Case 'accepts a short password but marks it weak and allows the override' {
    $r = Test-AutoVMPassword -Password 'bot'
    Assert-True $r.IsValid 'a short password is usable behind NAT'
    Assert-True $r.IsWeak
    Assert-True $r.AllowWeak 'the installer needs the weak-password override or it prompts'
}

Test-Case 'scores a long mixed password as strong and does not set the override' {
    $r = Test-AutoVMPassword -Password 'Correct-Horse-9!'
    Assert-True $r.IsValid
    Assert-False $r.IsWeak
    Assert-False $r.AllowWeak
}

Test-Case 'treats a well-known password as weak whatever its length' {
    Assert-True (Test-AutoVMPassword -Password 'password').IsWeak
}

Test-Case 'rejects control characters that would corrupt the answer file' {
    Assert-False (Test-AutoVMPassword -Password "line`nbreak").IsValid
    Assert-False (Test-AutoVMPassword -Password "tab`there").IsValid
}

# ---------------------------------------------------------------- planning
Describe-Group 'Machine planning'

$kali = Get-AutoVMGuestCatalog -Id 'kali'

Test-Case 'gives an 8 GB device a 3072 MB guest' {
    $plan = New-AutoVMPlan -HostProfile (New-TestHostProfile -RamGB 8) -Guest $kali
    Assert-Equal 3072 $plan.RamMB
}

Test-Case 'never gives the guest more than half of host memory' {
    foreach ($gb in 4, 6, 8, 12, 16, 32, 64) {
        $plan = New-AutoVMPlan -HostProfile (New-TestHostProfile -RamGB $gb) -Guest $kali
        $half = $gb * 1024 / 2
        Assert-True ($plan.RamMB -le $half) "a $gb GB host was given $($plan.RamMB) MB, which exceeds half"
    }
}

Test-Case 'caps the guest at 8192 MB however large the device is' {
    $plan = New-AutoVMPlan -HostProfile (New-TestHostProfile -RamGB 128) -Guest $kali
    Assert-Equal 8192 $plan.RamMB
}

Test-Case 'never drops below the guest minimum' {
    $plan = New-AutoVMPlan -HostProfile (New-TestHostProfile -RamGB 4) -Guest $kali
    Assert-True ($plan.RamMB -ge $kali.minimumRamMB)
}

Test-Case 'allocates half the logical cores, clamped to four' {
    Assert-Equal 2 (New-AutoVMPlan -HostProfile (New-TestHostProfile -Cores 4) -Guest $kali).Cpus
    Assert-Equal 4 (New-AutoVMPlan -HostProfile (New-TestHostProfile -Cores 16) -Guest $kali).Cpus
    Assert-Equal 1 (New-AutoVMPlan -HostProfile (New-TestHostProfile -Cores 1) -Guest $kali).Cpus
}

Test-Case 'shrinks the disk to fit a small volume, leaving host headroom' {
    $plan = New-AutoVMPlan -HostProfile (New-TestHostProfile -FreeGB 50) -Guest $kali
    Assert-True ($plan.DiskGB -lt 60) "expected a reduced disk, got $($plan.DiskGB) GB"
    Assert-True ($plan.DiskGB -ge $kali.minimumDiskGB)
}

Test-Case 'uses the full preferred disk when there is room' {
    $plan = New-AutoVMPlan -HostProfile (New-TestHostProfile -FreeGB 400) -Guest $kali
    Assert-Equal 60 $plan.DiskGB
}

Test-Case 'chooses the light package set on a small device and the full set on a large one' {
    Assert-Equal 'Light' (New-AutoVMPlan -HostProfile (New-TestHostProfile -RamGB 8) -Guest $kali).ProfileName
    Assert-Equal 'Full' (New-AutoVMPlan -HostProfile (New-TestHostProfile -RamGB 32) -Guest $kali).ProfileName
}

Test-Case 'honours an explicit profile override' {
    Assert-Equal 'Full' (New-AutoVMPlan -HostProfile (New-TestHostProfile -RamGB 8) -Guest $kali -Profile Full).ProfileName
    Assert-Equal 'Light' (New-AutoVMPlan -HostProfile (New-TestHostProfile -RamGB 32) -Guest $kali -Profile Light).ProfileName
}

Test-Case 'warns about memory pressure on a small device' {
    $plan = New-AutoVMPlan -HostProfile (New-TestHostProfile -RamGB 6) -Guest $kali
    Assert-True (@($plan.Warnings) -match 'Close browsers').Count
}

Test-Case 'picks the volume with the most free space when C: is too small' {
    $volumes = @(
        [pscustomobject]@{ Letter = 'C'; SizeGB = 476; FreeGB = 8; FreePct = 1.7 }
        [pscustomobject]@{ Letter = 'D'; SizeGB = 900; FreeGB = 500; FreePct = 55 }
    )
    $chosen = Select-AutoVMTargetVolume -Volumes $volumes -RequiredGB 45
    Assert-Equal 'D' $chosen.Letter
}

Test-Case 'prefers C: when it is large enough' {
    $volumes = @(
        [pscustomobject]@{ Letter = 'C'; SizeGB = 476; FreeGB = 300; FreePct = 60 }
        [pscustomobject]@{ Letter = 'D'; SizeGB = 900; FreeGB = 500; FreePct = 55 }
    )
    Assert-Equal 'C' (Select-AutoVMTargetVolume -Volumes $volumes -RequiredGB 45).Letter
}

Test-Case 'returns nothing when no volume can hold the build' {
    $volumes = @([pscustomobject]@{ Letter = 'C'; SizeGB = 476; FreeGB = 8; FreePct = 1.7 })
    Assert-True ($null -eq (Select-AutoVMTargetVolume -Volumes $volumes -RequiredGB 45))
}

# ---------------------------------------------------------------- gates
Describe-Group 'Pre-flight gates'

Test-Case 'a healthy device is ready' {
    $verdict = Get-AutoVMGateVerdict -Gates (Test-AutoVMGate -HostProfile (New-TestHostProfile) -RequireElevation)
    Assert-Equal 'Ready' $verdict.Status
}

Test-Case 'virtualization disabled in firmware blocks the build' {
    $gates = Test-AutoVMGate -HostProfile (New-TestHostProfile -VT $false) -RequireElevation
    $verdict = Get-AutoVMGateVerdict -Gates $gates
    Assert-Equal 'Blocked' $verdict.Status
    Assert-True (@($verdict.Halts.Id) -contains 'G1')
    Assert-Match 'firmware' ($gates | Where-Object Id -eq 'G1').Remediation
}

Test-Case 'a CPU without SLAT blocks the build' {
    $verdict = Get-AutoVMGateVerdict -Gates (Test-AutoVMGate -HostProfile (New-TestHostProfile -Slat '') -RequireElevation)
    Assert-Equal 'Blocked' $verdict.Status
}

Test-Case 'insufficient disk blocks the build' {
    $verdict = Get-AutoVMGateVerdict -Gates (Test-AutoVMGate -HostProfile (New-TestHostProfile -FreeGB 10) -RequiredDiskGB 45 -RequireElevation)
    Assert-True (@($verdict.Halts.Id) -contains 'G4')
}

Test-Case 'a competing hypervisor asks rather than blocks' {
    $verdict = Get-AutoVMGateVerdict -Gates (Test-AutoVMGate -HostProfile (New-TestHostProfile -Hypervisor $true) -RequireElevation)
    Assert-Equal 'NeedsDecision' $verdict.Status
    Assert-True (@($verdict.Decisions.Id) -contains 'G5')
}

Test-Case 'the virtualization trade-off never suggests disabling host security' {
    $g5 = (Test-AutoVMGate -HostProfile (New-TestHostProfile -Hypervisor $true)) | Where-Object Id -eq 'G5'
    Assert-Match 'does not disable' $g5.Remediation
}

Test-Case 'missing elevation blocks only when elevation is required' {
    $unelevated = New-TestHostProfile -Elevated $false
    Assert-Equal 'Blocked' (Get-AutoVMGateVerdict -Gates (Test-AutoVMGate -HostProfile $unelevated -RequireElevation)).Status
    Assert-Equal 'Ready' (Get-AutoVMGateVerdict -Gates (Test-AutoVMGate -HostProfile $unelevated)).Status
}

Test-Case 'every gate is evaluated even after one fails' {
    $gates = Test-AutoVMGate -HostProfile (New-TestHostProfile -VT $false -FreeGB 1) -RequireElevation
    Assert-True ($gates.Count -ge 8) "expected the full matrix, got $($gates.Count)"
}

# ---------------------------------------------------------------- catalog
Describe-Group 'Image resolution'

Test-Case 'selects the newest image from a directory listing' {
    $listing = @'
<a href="kali-linux-2025.1-installer-amd64.iso">kali-linux-2025.1-installer-amd64.iso</a>
<a href="kali-linux-2025.3-installer-amd64.iso">kali-linux-2025.3-installer-amd64.iso</a>
<a href="kali-linux-2024.4-installer-amd64.iso">kali-linux-2024.4-installer-amd64.iso</a>
<a href="kali-linux-2025.3-live-amd64.iso">not the installer</a>
'@
    Assert-Equal 'kali-linux-2025.3-installer-amd64.iso' (Select-AutoVMIsoName -Listing $listing -Pattern $kali.isoPattern)
}

Test-Case 'returns nothing when a listing has no matching image' {
    Assert-True ($null -eq (Select-AutoVMIsoName -Listing '<html>nothing here</html>' -Pattern $kali.isoPattern))
}

Test-Case 'reads the checksum for one file out of a SHA256SUMS document' {
    $sums = @'
1111111111111111111111111111111111111111111111111111111111111111  kali-linux-2025.1-installer-amd64.iso
abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789  kali-linux-2025.3-installer-amd64.iso
'@
    Assert-Equal 'abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789' `
        (Select-AutoVMChecksum -Sums $sums -FileName 'kali-linux-2025.3-installer-amd64.iso')
}

Test-Case 'returns nothing when the checksum document does not list the file' {
    Assert-True ($null -eq (Select-AutoVMChecksum -Sums 'nothing here' -FileName 'kali.iso'))
}

Test-Case 'the catalog exposes the expected guests' {
    $ids = (Get-AutoVMGuestCatalog).id
    Assert-True ($ids -contains 'kali')
    Assert-True ($ids -contains 'debian')
}

Test-Case 'an unknown guest id is rejected' {
    Assert-Throws { Get-AutoVMGuestCatalog -Id 'plan9' } 'Unknown guest'
}

# ---------------------------------------------------------------- preseed
Describe-Group 'Installer answer file'

$plan8 = New-AutoVMPlan -HostProfile (New-TestHostProfile -RamGB 8) -Guest $kali -VMName 'AutoVM-kali'

Test-Case 'creates a capitalised login in lowercase and renames it afterwards' {
    $text = New-AutoVMPreseed -Plan $plan8 -Guest $kali -UserName 'Kali' -Password (New-TestSecureString 'bot') -AllowWeakPassword
    Assert-MatchCase 'passwd/username\s+string kali' $text 'the installer must be given the lowercase form'
    Assert-NotMatchCase 'passwd/username\s+string Kali' $text 'a capital would be rejected by user-setup'
    Assert-Match 'usermod --badname -l Kali kali' $text 'the rename must happen in late_command'
    Assert-Match 'chown -R Kali:kali' $text 'ownership must be repaired, group left lowercase'
}

Test-Case 'omits the rename entirely for an all-lowercase login' {
    $text = New-AutoVMPreseed -Plan $plan8 -Guest $kali -UserName 'analyst' -Password (New-TestSecureString 'bot') -AllowWeakPassword
    Assert-NotMatch 'usermod --badname -l' $text
    Assert-Match 'passwd/username\s+string analyst' $text
}

Test-Case 'writes the chosen password into both password fields' {
    $text = New-AutoVMPreseed -Plan $plan8 -Guest $kali -UserName 'analyst' -Password (New-TestSecureString 'S3cret-Pass!')
    Assert-Match 'user-password\s+password S3cret-Pass!' $text
    Assert-Match 'user-password-again\s+password S3cret-Pass!' $text
}

Test-Case 'sets the weak-password override only when asked' {
    $weak = New-AutoVMPreseed -Plan $plan8 -Guest $kali -UserName 'a' -Password (New-TestSecureString 'bot') -AllowWeakPassword
    $strong = New-AutoVMPreseed -Plan $plan8 -Guest $kali -UserName 'a' -Password (New-TestSecureString 'Correct-Horse-9!')
    Assert-Match 'allow-password-weak\s+boolean true' $weak
    Assert-Match 'allow-password-weak\s+boolean false' $strong
}

Test-Case 'answers every question that would otherwise stop an unattended install' {
    $text = New-AutoVMPreseed -Plan $plan8 -Guest $kali -UserName 'analyst' -Password (New-TestSecureString 'bot') -AllowWeakPassword
    foreach ($key in @(
            'partman/confirm\s+boolean true'
            'partman/confirm_nooverwrite\s+boolean true'
            'partman-partitioning/confirm_write_new_label\s+boolean true'
            'partman-efi/non_efi_system\s+boolean true'
            'grub-installer/bootdev'
            'finish-install/reboot_in_progress'
            'passwd/root-login\s+boolean false'
        )) {
        Assert-Match $key $text "a missing '$key' turns an unattended install into one that waits forever"
    }
}

Test-Case 'includes the package set the plan chose' {
    $text = New-AutoVMPreseed -Plan $plan8 -Guest $kali -UserName 'analyst' -Password (New-TestSecureString 'bot') -AllowWeakPassword
    Assert-Match 'kali-desktop-xfce' $text
}

Test-Case 'refuses to render an answer file for an invalid login' {
    Assert-Throws { New-AutoVMPreseed -Plan $plan8 -Guest $kali -UserName 'root' -Password (New-TestSecureString 'x') } 'Invalid guest login'
}

Test-Case 'uses the mirror declared by the guest' {
    $debian = Get-AutoVMGuestCatalog -Id 'debian'
    $planD = New-AutoVMPlan -HostProfile (New-TestHostProfile) -Guest $debian
    $text = New-AutoVMPreseed -Plan $planD -Guest $debian -UserName 'dev' -Password (New-TestSecureString 'bot') -AllowWeakPassword
    Assert-Match 'mirror/http/hostname\s+string deb\.debian\.org' $text
}

# ---------------------------------------------------------------- protection
Describe-Group 'Deletion safety'

Test-Case 'a WSL distribution disk is protected' {
    Assert-True (Test-AutoVMProtectedPath -Path 'C:\Users\me\AppData\Local\Packages\CanonicalGroupLimited.Ubuntu_79rhkp1\LocalState\ext4.vhdx')
}

Test-Case 'recovery and Windows.old images are protected' {
    Assert-True (Test-AutoVMProtectedPath -Path 'C:\Recovery\WindowsRE\winre.wim')
    Assert-True (Test-AutoVMProtectedPath -Path 'C:\Windows.old\somedisk.vhdx')
}

Test-Case 'a currently attached image is protected' {
    $path = 'D:\Images\attached.vhdx'
    Assert-True (Test-AutoVMProtectedPath -Path $path -MountedImages @($path))
    Assert-False (Test-AutoVMProtectedPath -Path $path -MountedImages @('D:\other.vhdx'))
}

Test-Case 'an ordinary VirtualBox disk is not protected' {
    Assert-False (Test-AutoVMProtectedPath -Path 'C:\Users\me\VirtualBox VMs\old\old.vdi')
}

Test-Case 'system directories are excluded from the scan entirely' {
    Assert-True (Test-AutoVMExcludedPath -Path 'C:\Windows\System32\thing.vhdx')
    Assert-True (Test-AutoVMExcludedPath -Path 'C:\Users\me\OneDrive\backup.vdi')
    Assert-False (Test-AutoVMExcludedPath -Path 'D:\VMs\guest.vdi')
}

Test-Case 'deletion without the exact confirmation is refused' {
    $candidates = @([pscustomobject]@{ Kind = 'DiskImage'; Name = 'x.vdi'; Path = 'D:\x.vdi'; SizeGB = 1; Protected = $false })
    Assert-Throws { Invoke-AutoVMTeardown -Candidates $candidates -Confirmation 'destroy' -Confirm:$false } 'AUTOVM-R4'
    Assert-Throws { Invoke-AutoVMTeardown -Candidates $candidates -Confirmation 'yes' -Confirm:$false } 'AUTOVM-R4'
    Assert-Throws { Invoke-AutoVMTeardown -Candidates $candidates -Confirmation '' -Confirm:$false } 'AUTOVM-R4'
}

# ---------------------------------------------------------------- redaction
Describe-Group 'Secret handling'

Test-Case 'a registered secret never appears in a log line' {
    Clear-AutoVMSecret
    Register-AutoVMSecret -Value 'hunter2'
    Assert-Equal 'password is ********' (Protect-AutoVMString 'password is hunter2')
    Clear-AutoVMSecret
}

Test-Case 'redaction covers every occurrence' {
    Clear-AutoVMSecret
    Register-AutoVMSecret -Value 'abc'
    Assert-Equal '******** and ********' (Protect-AutoVMString 'abc and abc')
    Clear-AutoVMSecret
}

Test-Case 'a secure string round-trips exactly' {
    $result = Invoke-InModule { ConvertFrom-AutoVMSecureString -Secure (ConvertTo-SecureString 'P@ss w0rd!' -AsPlainText -Force) }
    Assert-Equal 'P@ss w0rd!' $result
}

Test-Case 'the credential plan reports the installer name and the rename' {
    $plan = New-AutoVMCredentialPlan -UserName 'Analyst' -Password (New-TestSecureString 'bot')
    Assert-Equal 'analyst' $plan.InstallerName
    Assert-Equal 'Analyst' $plan.UserName
    Assert-True $plan.RequiresRename
    Assert-True $plan.AllowWeak
    Assert-True $plan.IsValid
}

Test-Case 'an invalid login produces an invalid credential plan rather than throwing' {
    Assert-False (New-AutoVMCredentialPlan -UserName 'ro ot' -Password (New-TestSecureString 'bot')).IsValid
}

# ---------------------------------------------------------------- state
Describe-Group 'Resume ledger'

Test-Case 'a phase result survives a reload' {
    $root = Join-Path $env:AUTOVM_ROOT 'ledger'
    Initialize-AutoVMRoot -Root $root | Out-Null
    $state = New-AutoVMState -Root $root
    Complete-AutoVMPhase -State $state -Id 'P1' -Result 'PASS' -Created @('a.json') -Root $root | Out-Null

    $reloaded = Get-AutoVMState -Root $root
    Assert-True (Test-AutoVMPhaseComplete -State $reloaded -Id 'P1')
    Assert-False (Test-AutoVMPhaseComplete -State $reloaded -Id 'P2')
}

Test-Case 'a repeated phase replaces its earlier record rather than duplicating it' {
    $root = Join-Path $env:AUTOVM_ROOT 'ledger2'
    Initialize-AutoVMRoot -Root $root | Out-Null
    $state = New-AutoVMState -Root $root
    Complete-AutoVMPhase -State $state -Id 'P3' -Result 'FAIL' -Root $root | Out-Null
    Complete-AutoVMPhase -State $state -Id 'P3' -Result 'PASS' -Root $root | Out-Null

    $reloaded = Get-AutoVMState -Root $root
    Assert-Equal 1 (@($reloaded.completed | Where-Object { $_.id -eq 'P3' }).Count)
    Assert-True (Test-AutoVMPhaseComplete -State $reloaded -Id 'P3')
}

Test-Case 'a gate decision is recorded with its answer' {
    $root = Join-Path $env:AUTOVM_ROOT 'ledger3'
    Initialize-AutoVMRoot -Root $root | Out-Null
    $state = New-AutoVMState -Root $root
    Add-AutoVMDecision -State $state -Gate 'G5' -Question 'accept slower guest?' -Answer 'accepted' -Root $root
    Assert-Equal 'accepted' (Get-AutoVMState -Root $root).decisions[0].answer
}

# ---------------------------------------------------------------- handover
Describe-Group 'Handover note'

Test-Case 'tells the user the exact login and warns about case' {
    $note = New-AutoVMHandoverNote -Plan $plan8 -UserName 'Kali' -ShortcutPath 'C:\Users\me\Desktop\AutoVM Control Center.lnk'
    Assert-Match 'Sign in as\s+Kali' $note
    Assert-Match 'case-sensitive' $note
}

Test-Case 'states the network condition attached to the password' {
    $note = New-AutoVMHandoverNote -Plan $plan8 -UserName 'Kali' -ShortcutPath 'x.lnk'
    Assert-Match 'bridged' $note
    Assert-Match 'Outbound only' $note
}

Test-Case 'lists anything that was removed' {
    $note = New-AutoVMHandoverNote -Plan $plan8 -UserName 'Kali' -ShortcutPath 'x.lnk' -Destroyed @('OldVM')
    Assert-Match 'Removed during setup' $note
    Assert-Match 'OldVM' $note
}

Test-Case 'does not carry the password and says so' {
    $note = New-AutoVMHandoverNote -Plan $plan8 -UserName 'Kali' -ShortcutPath 'x.lnk'
    Assert-Match 'did not keep a copy' $note
    Assert-NotMatch 'S3cret-Pass' $note
}

# ---------------------------------------------------------------- summary
Write-Host ''
Write-Host ('{0} passed, {1} failed' -f $script:Passed, $script:Failed) -ForegroundColor $(if ($script:Failed) { 'Red' } else { 'Green' })

if (Test-Path $env:AUTOVM_ROOT) { Remove-Item -LiteralPath $env:AUTOVM_ROOT -Recurse -Force -ErrorAction SilentlyContinue }
exit $(if ($script:Failed) { 1 } else { 0 })
