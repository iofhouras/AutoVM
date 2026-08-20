<#
    Pre-flight gates.

    Pure functions over a host profile and a plan, so the whole gate matrix can
    be unit-tested without a machine to test it on. Severity decides what the
    caller does:

        Halt      the build cannot proceed and there is a stated remediation
        Decide    a trade-off only a human may accept
        Constrain proceed, but with a reduced plan
        Info      recorded, no action
#>

function Test-AutoVMGate {
    <#
        .SYNOPSIS
        Evaluates every pre-flight gate in one pass.

        .DESCRIPTION
        All gates are evaluated even after one fails, so the caller can report
        the whole picture rather than the first problem it tripped over.

        .PARAMETER HostProfile
        Output of Get-AutoVMHostProfile.

        .PARAMETER RequiredDiskGB
        Free space the chosen plan needs on one fixed volume.

        .PARAMETER RequireElevation
        Whether the caller intends to run phases that install drivers.
    #>
    [CmdletBinding()]
    [OutputType([psobject[]])]
    param(
        [Parameter(Mandatory)][psobject]$HostProfile,
        [double]$RequiredDiskGB = 45,
        [switch]$RequireElevation,
        [double]$MinimumRamGB = 6
    )

    $gates = [System.Collections.Generic.List[psobject]]::new()

    function New-Gate {
        param($Id, $Title, $Severity, $Passed, $Detail, $Remediation)
        [pscustomobject]@{
            Id          = $Id
            Title       = $Title
            Severity    = $Severity
            Passed      = [bool]$Passed
            Detail      = $Detail
            Remediation = $Remediation
        }
    }

    $gates.Add((New-Gate 'G1' 'Hardware virtualization enabled' 'Halt' $HostProfile.VTEnabled `
        ("VirtualizationFirmwareEnabled = {0}" -f $HostProfile.VTEnabled) `
        'Reboot into firmware setup (F1/F2 or the Novo button on Lenovo), enable Intel VT-x or AMD-V under Security, then run the scan again.'))

    $slatOk = -not [string]::IsNullOrWhiteSpace([string]$HostProfile.SLAT)
    $gates.Add((New-Gate 'G2' 'Second level address translation' 'Halt' $slatOk `
        ("SLAT = {0}" -f $(if ($slatOk) { $HostProfile.SLAT } else { 'not reported' })) `
        'This CPU cannot run a modern guest at usable speed. There is no software remediation.'))

    $ramOk = [double]$HostProfile.TotalRAM_GB -ge $MinimumRamGB
    $gates.Add((New-Gate 'G3' 'Sufficient host memory' 'Constrain' $ramOk `
        ("{0} GB installed, {1} GB required" -f $HostProfile.TotalRAM_GB, $MinimumRamGB) `
        'Close other applications, or add memory. Below the minimum the guest cannot be given a workable share.'))

    $best = @($HostProfile.Volumes | Sort-Object FreeGB -Descending | Select-Object -First 1)
    $freeGB = if ($best) { [double]$best[0].FreeGB } else { 0 }
    $diskOk = $freeGB -ge $RequiredDiskGB
    $gates.Add((New-Gate 'G4' 'Free disk space' 'Halt' $diskOk `
        ("best fixed volume has {0} GB free, {1} GB required" -f $freeGB, $RequiredDiskGB) `
        'Free space on a fixed volume, or choose a different volume for the virtual machine on the previous screen.'))

    $contended = [bool]$HostProfile.HypervisorPresent -or ([int]$HostProfile.VBSRunning -eq 2)
    $gates.Add((New-Gate 'G5' 'Exclusive use of the CPU virtualization extensions' 'Decide' (-not $contended) `
        ("HypervisorPresent = {0}, VBS status = {1}, Memory Integrity = {2}" -f $HostProfile.HypervisorPresent, $HostProfile.VBSRunning, $HostProfile.HVCIRunning) `
        'Windows security features (VBS, Memory Integrity, WSL2) already own the virtualization extensions, so the guest runs in a slower hosted mode - typically 15-35% less CPU throughput. AutoVM does not disable them: that would break WSL2 and weaken the host. Continue and accept the slower guest, or turn those features off yourself and run the scan again.'))

    $gates.Add((New-Gate 'G6' 'Windows edition' 'Info' $true `
        ("{0}{1}" -f $HostProfile.OSCaption, $(if ($HostProfile.IsHomeSKU) { ' (no Hyper-V Manager, no gpedit - VirtualBox is the right hypervisor here)' } else { '' })) `
        ''))

    $elevationOk = if ($RequireElevation) { [bool]$HostProfile.IsElevated } else { $true }
    $gates.Add((New-Gate 'G7' 'Administrator rights' 'Halt' $elevationOk `
        ("elevated = {0}" -f $HostProfile.IsElevated) `
        'Installing the hypervisor loads a kernel driver, which needs administrator rights. Close AutoVM and start it again with "Run as administrator".'))

    $conflict = [bool]$HostProfile.VMwareInstalled
    $gates.Add((New-Gate 'G8' 'No competing desktop hypervisor' 'Decide' (-not $conflict) `
        ("VMware Workstation/Player detected = {0}" -f $conflict) `
        'VMware is installed. Both products can coexist on current versions, but a running VMware VM will contend for the same extensions. Shut down any VMware guests before starting the build.'))

    return $gates.ToArray()
}

function Get-AutoVMGateVerdict {
    <#
        .SYNOPSIS
        Reduces a gate array to a single decision for the caller.

        .OUTPUTS
        Blocked / NeedsDecision / Ready, plus the gates that produced it.
    #>
    [CmdletBinding()]
    [OutputType([psobject])]
    param([Parameter(Mandatory)][AllowEmptyCollection()][psobject[]]$Gates)

    $halts = @($Gates | Where-Object { -not $_.Passed -and $_.Severity -eq 'Halt' })
    $decisions = @($Gates | Where-Object { -not $_.Passed -and $_.Severity -eq 'Decide' })
    $constraints = @($Gates | Where-Object { -not $_.Passed -and $_.Severity -eq 'Constrain' })

    $status = if ($halts.Count -gt 0) { 'Blocked' }
    elseif ($decisions.Count -gt 0) { 'NeedsDecision' }
    else { 'Ready' }

    return [pscustomobject]@{
        Status      = $status
        Halts       = $halts
        Decisions   = $decisions
        Constraints = $constraints
        Summary     = switch ($status) {
            'Blocked' { 'This device cannot build the virtual machine yet: {0}' -f (($halts | ForEach-Object { $_.Id }) -join ', ') }
            'NeedsDecision' { 'Ready, with a trade-off to confirm: {0}' -f (($decisions | ForEach-Object { $_.Id }) -join ', ') }
            default { 'This device is ready to build.' }
        }
    }
}
