<#
    Planning: turn a host profile into a machine specification that fits it.

    Pure arithmetic, no side effects, so the sizing rules are unit-testable and
    the GUI can show a plan before anything is installed.
#>

function New-AutoVMPlan {
    <#
        .SYNOPSIS
        Produces the VM specification for this device.

        .DESCRIPTION
        Sizing rules, in order:
          * Guest memory is 40% of host memory, rounded down to a 512 MB step,
            clamped to the guest's own minimum and to half the host - never more.
          * vCPUs are half the logical cores, clamped to the guest minimum and 4.
          * The disk is capped by free space on the chosen volume, leaving a
            15 GB working margin for the host.
          * A small host gets the light desktop metapackage and no audio device.

        .PARAMETER HostProfile
        Output of Get-AutoVMHostProfile.

        .PARAMETER Guest
        A catalog entry from Get-AutoVMGuestCatalog.
    #>
    [CmdletBinding()]
    [OutputType([psobject])]
    param(
        [Parameter(Mandatory)][psobject]$HostProfile,
        [Parameter(Mandatory)][psobject]$Guest,
        [string]$VMName = 'AutoVM-Guest',
        [ValidateSet('Auto', 'Light', 'Full')][string]$Profile = 'Auto',
        [string]$PreferredVolume
    )

    $hostRamMB = [int]([double]$HostProfile.TotalRAM_GB * 1024)
    $guestMinMB = [int]$Guest.minimumRamMB

    $target = [int]([math]::Floor($hostRamMB * 0.40 / 512) * 512)
    $ceiling = [int]([math]::Floor($hostRamMB * 0.50 / 512) * 512)
    $ramMB = [math]::Max($guestMinMB, [math]::Min($target, $ceiling))
    $ramMB = [math]::Min($ramMB, 8192)

    $cores = [math]::Max(1, [int]$HostProfile.LogicalCores)
    $cpus = [math]::Max([int]$Guest.minimumCpus, [math]::Min([int][math]::Floor($cores / 2), 4))

    $light = switch ($Profile) {
        'Light' { $true }
        'Full' { $false }
        default { [double]$HostProfile.TotalRAM_GB -lt 12 }
    }

    $packages = if ($light) { [string[]]$Guest.packages.light } else { [string[]]$Guest.packages.full }

    # Disk: the guest's preferred maximum, trimmed to what the volume can host.
    $preferred = [int]$Guest.preferredDiskGB
    $margin = 15
    $isoGB = [double]$Guest.approximateIsoGB
    $requiredGB = [double]$Guest.minimumDiskGB + $isoGB + 5

    $volume = Select-AutoVMTargetVolume -Volumes @($HostProfile.Volumes) -RequiredGB $requiredGB `
        -PreferredLetter $(if ($PreferredVolume) { $PreferredVolume } else { 'C' })

    $diskGB = $preferred
    if ($volume) {
        $usable = [int][math]::Floor([double]$volume.FreeGB - $isoGB - $margin)
        if ($usable -lt $preferred) { $diskGB = [math]::Max([int]$Guest.minimumDiskGB, $usable) }
    }

    $warnings = [System.Collections.Generic.List[string]]::new()
    if ([double]$HostProfile.TotalRAM_GB -lt 8) {
        $warnings.Add("This device has $($HostProfile.TotalRAM_GB) GB of memory. Close browsers and other large applications before starting the virtual machine.")
    }
    if ($light -and $Profile -eq 'Auto') {
        $warnings.Add('The light desktop package set was chosen automatically to fit this device. Extra tools can be installed inside the guest later.')
    }
    if ([bool]$HostProfile.HypervisorPresent -or [int]$HostProfile.VBSRunning -eq 2) {
        $warnings.Add('Windows virtualization-based security is active, so the guest will run in a slower hosted mode. AutoVM leaves those protections switched on.')
    }
    if ($volume -and $volume.Letter -ne 'C') {
        $warnings.Add("The virtual machine will be stored on drive $($volume.Letter): because it has the most free space.")
    }
    if (-not $volume) {
        $warnings.Add("No fixed volume has the $requiredGB GB this build needs.")
    }

    return [pscustomobject]@{
        VMName          = $VMName
        GuestId         = $Guest.id
        GuestName       = $Guest.name
        OsType          = $Guest.vboxOsType
        RamMB           = [int]$ramMB
        Cpus            = [int]$cpus
        VramMB          = 128
        DiskGB          = [int]$diskGB
        Packages        = $packages
        ProfileName     = if ($light) { 'Light' } else { 'Full' }
        Audio           = (-not $light)
        Accelerate3D    = $false
        Firmware        = 'efi'
        NetworkMode     = 'nat'
        TargetVolume    = if ($volume) { [string]$volume.Letter } else { $null }
        MachineFolder   = if ($volume) { '{0}:\AutoVM\Machines' -f $volume.Letter } else { $null }
        RequiredDiskGB  = [double]$requiredGB
        EstimatedMinutes = [int]$Guest.estimatedMinutes
        HostRamShare    = [math]::Round(100 * $ramMB / [math]::Max(1, $hostRamMB), 1)
        Warnings        = $warnings.ToArray()
    }
}

function Format-AutoVMPlanSummary {
    <#  One-line human summary used in logs and the review screen.  #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][psobject]$Plan)

    return ('{0}: {1} MB RAM ({2}% of host), {3} vCPU, {4} GB disk on {5}:, {6} package set' -f
        $Plan.GuestName, $Plan.RamMB, $Plan.HostRamShare, $Plan.Cpus, $Plan.DiskGB,
        $(if ($Plan.TargetVolume) { $Plan.TargetVolume } else { '?' }), $Plan.ProfileName)
}
