<#
    Host reconnaissance.

    This is the "configure to the device it is on" step: one read-only sweep of
    the machine that everything downstream plans against. Nothing here writes
    outside the manifests folder, so it is free to re-run at any time.
#>

function Get-AutoVMHostProfile {
    <#
        .SYNOPSIS
        Collects the full host profile used for planning and gate evaluation.

        .PARAMETER Path
        Optional path to write the profile to as JSON.

        .PARAMETER Simulated
        Returns a representative profile without touching the machine. Used by
        the test suite and by the GUI's preview mode on non-Windows hosts.

        .OUTPUTS
        A PSCustomObject with OS, CPU, memory, storage, hypervisor and
        installed-tool facts.
    #>
    [CmdletBinding()]
    [OutputType([psobject])]
    param(
        [string]$Path,
        [switch]$Simulated
    )

    if ($Simulated -or -not (Test-AutoVMWindows)) {
        $hostProfile = [pscustomobject]@{
            CollectedAt       = (Get-Date).ToUniversalTime().ToString('o')
            Simulated         = $true
            ComputerModel     = 'SIMULATED HOST'
            OSCaption         = 'Microsoft Windows 11 Home'
            OSBuild           = '10.0.26100.2314'
            IsHomeSKU         = $true
            TotalRAM_GB       = 7.73
            FreeRAM_GB        = 2.4
            CPUName           = 'Simulated CPU'
            LogicalCores      = 8
            VTEnabled         = $true
            SLAT              = 'Extended Page Tables'
            HypervisorPresent = $true
            VBSRunning        = 2
            HVCIRunning       = $true
            WSLInstalled      = $true
            VMPlatform        = 'Enabled'
            Volumes           = @(
                [pscustomobject]@{ Letter = 'C'; SizeGB = 476.4; FreeGB = 120.5; FreePct = 25.3 }
            )
            VBoxInstalled     = $false
            VBoxVersion       = ''
            VMwareInstalled   = $false
            IsElevated        = $false
            PSVersion         = $PSVersionTable.PSVersion.ToString()
        }
        if ($Path) { $hostProfile | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $Path -Encoding utf8 }
        return $hostProfile
    }

    Write-AutoVMLog -Level Step -Message 'Reading host profile' -Percent 5

    $os = Get-CimInstance Win32_OperatingSystem
    $cs = Get-CimInstance Win32_ComputerSystem
    $cpu = Get-CimInstance Win32_Processor | Select-Object -First 1

    $ubr = try { (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction Stop).UBR } catch { 0 }

    $dg = try {
        Get-CimInstance -Namespace 'root\Microsoft\Windows\DeviceGuard' -ClassName Win32_DeviceGuard -ErrorAction Stop
    } catch { $null }

    $volumes = @(
        Get-Volume -ErrorAction SilentlyContinue |
            Where-Object { $_.DriveType -eq 'Fixed' -and $_.DriveLetter } |
            ForEach-Object {
                [pscustomobject]@{
                    Letter  = [string]$_.DriveLetter
                    SizeGB  = [math]::Round($_.Size / 1GB, 1)
                    FreeGB  = [math]::Round($_.SizeRemaining / 1GB, 1)
                    FreePct = if ($_.Size) { [math]::Round(100 * $_.SizeRemaining / $_.Size, 1) } else { 0 }
                }
            }
    )

    $vboxKey = try { Get-ItemProperty 'HKLM:\SOFTWARE\Oracle\VirtualBox' -ErrorAction Stop } catch { $null }

    $vmPlatform = try {
        (Get-WindowsOptionalFeature -Online -FeatureName VirtualMachinePlatform -ErrorAction Stop).State.ToString()
    } catch { 'Unknown' }

    $hostProfile = [pscustomobject]@{
        CollectedAt       = (Get-Date).ToUniversalTime().ToString('o')
        Simulated         = $false
        ComputerModel     = ('{0} {1}' -f $cs.Manufacturer, $cs.Model).Trim()
        OSCaption         = $os.Caption
        OSBuild           = '{0}.{1}' -f $os.Version, $ubr
        IsHomeSKU         = [bool]($os.Caption -match 'Home')
        TotalRAM_GB       = [math]::Round($cs.TotalPhysicalMemory / 1GB, 2)
        FreeRAM_GB        = [math]::Round($os.FreePhysicalMemory / 1MB, 2)
        CPUName           = $cpu.Name
        LogicalCores      = [int]$cpu.NumberOfLogicalProcessors
        VTEnabled         = [bool]$cpu.VirtualizationFirmwareEnabled
        SLAT              = [string]$cpu.SecondLevelAddressTranslationExtensions
        HypervisorPresent = [bool]$cs.HypervisorPresent
        VBSRunning        = if ($dg) { [int]$dg.VirtualizationBasedSecurityStatus } else { 0 }
        HVCIRunning       = if ($dg -and $dg.SecurityServicesRunning) { [bool]($dg.SecurityServicesRunning -contains 2) } else { $false }
        WSLInstalled      = [bool](Get-Command wsl.exe -ErrorAction SilentlyContinue)
        VMPlatform        = $vmPlatform
        Volumes           = $volumes
        VBoxInstalled     = [bool]$vboxKey
        VBoxVersion       = if ($vboxKey -and $vboxKey.PSObject.Properties.Name -contains 'Version') { [string]$vboxKey.Version } else { '' }
        VMwareInstalled   = [bool](Get-Service -Name 'VMAuthdService' -ErrorAction SilentlyContinue)
        IsElevated        = (Test-AutoVMElevated)
        PSVersion         = $PSVersionTable.PSVersion.ToString()
    }

    if ($Path) {
        $hostProfile | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $Path -Encoding utf8
        Write-AutoVMLog -Level Info -Message "Host profile written to $Path"
    }

    Write-AutoVMLog -Level Info -Message (
        '{0} | {1} | {2} GB RAM | {3} logical cores | VT-x {4}' -f
        $hostProfile.ComputerModel, $hostProfile.OSCaption, $hostProfile.TotalRAM_GB, $hostProfile.LogicalCores,
        $(if ($hostProfile.VTEnabled) { 'enabled' } else { 'DISABLED' })
    )

    return $hostProfile
}

function Select-AutoVMTargetVolume {
    <#
        .SYNOPSIS
        Chooses the fixed volume the guest disk should live on.

        .DESCRIPTION
        Pure function over the profile's volume list so it can be tested without
        a disk. Prefers the system volume when it comfortably fits, otherwise
        the fixed volume with the most free space.
    #>
    [CmdletBinding()]
    [OutputType([psobject])]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][psobject[]]$Volumes,
        [Parameter(Mandatory)][double]$RequiredGB,
        [string]$PreferredLetter = 'C'
    )

    $fitting = @($Volumes | Where-Object { $_.FreeGB -ge $RequiredGB })
    if (-not $fitting) { return $null }

    $preferred = @($fitting | Where-Object { $_.Letter -eq $PreferredLetter })
    if ($preferred) { return $preferred[0] }

    return ($fitting | Sort-Object FreeGB -Descending | Select-Object -First 1)
}
