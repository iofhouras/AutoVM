<#
    Managing a machine after it has been built.

    Everything the management screen needs: the machine list and its live state,
    the settings that are safe to change, snapshots, shared folders, export and
    removal. The validation is pure so it can be tested without a hypervisor;
    only the apply step talks to VirtualBox.
#>

function Get-AutoVMMachine {
    <#
        .SYNOPSIS
        Lists virtual machines with their live state and hardware.

        .PARAMETER Name
        Return one machine instead of all of them.

        .OUTPUTS
        Name, State, RamMB, Cpus, VramMB, DiskGB, DiskUsedGB, SnapshotCount,
        IPAddress, GuestOS, Directory, DiskPath and Clipboard.
    #>
    [CmdletBinding()]
    [OutputType([psobject[]])]
    param([string]$Name)

    $names = if ($Name) { @($Name) } else { Get-AutoVMVmName }
    $machines = [System.Collections.Generic.List[psobject]]::new()

    foreach ($vm in $names) {
        $info = @{}
        try {
            $result = Invoke-VBoxManage -Arguments @('showvminfo', $vm, '--machinereadable') `
                -IgnoreExitCode -TimeoutSeconds 60
            foreach ($line in $result.Lines) {
                if ($line -match '^(?<k>[^=]+)=(?<v>.*)$') {
                    $info[$Matches['k']] = $Matches['v'].Trim('"')
                }
            }
        } catch {
            Write-AutoVMLog -Level Debug -Message "Could not read '$vm': $($_.Exception.Message)"
            continue
        }
        if ($info.Count -eq 0) { continue }

        $diskPath = $null
        foreach ($key in $info.Keys) {
            if ($key -match '^SATA-\d+-\d+$' -and $info[$key] -like '*.vdi') { $diskPath = $info[$key]; break }
        }

        $usedGB = 0
        if ($diskPath -and (Test-Path -LiteralPath $diskPath)) {
            $usedGB = [math]::Round((Get-Item -LiteralPath $diskPath).Length / 1GB, 2)
        }

        $machines.Add([pscustomobject]@{
                Name          = $vm
                State         = if ($info.ContainsKey('VMState')) { $info['VMState'] } else { 'unknown' }
                RamMB         = [int](Get-AutoVMInfoValue $info 'memory' 0)
                Cpus          = [int](Get-AutoVMInfoValue $info 'cpus' 1)
                VramMB        = [int](Get-AutoVMInfoValue $info 'vram' 0)
                DiskGB        = 0
                DiskUsedGB    = $usedGB
                DiskPath      = $diskPath
                Directory     = if ($info.ContainsKey('CfgFile')) { Split-Path -Parent $info['CfgFile'] } else { $null }
                Clipboard     = Get-AutoVMInfoValue $info 'clipboard' 'disabled'
                DragAndDrop   = Get-AutoVMInfoValue $info 'draganddrop' 'disabled'
                NetworkMode   = Get-AutoVMInfoValue $info 'nic1' 'none'
                SnapshotCount = @($info.Keys | Where-Object { $_ -match '^SnapshotName' }).Count
                GuestOS       = Get-AutoVMGuestProperty -VMName $vm -Name '/VirtualBox/GuestInfo/OS/Product'
                IPAddress     = Get-AutoVMGuestProperty -VMName $vm -Name '/VirtualBox/GuestInfo/Net/0/V4/IP'
            })
    }
    return $machines.ToArray()
}

function Get-AutoVMInfoValue {
    [CmdletBinding()]
    param([hashtable]$Info, [string]$Key, $Default)
    if ($Info.ContainsKey($Key) -and $Info[$Key]) { return $Info[$Key] }
    return $Default
}

function Test-AutoVMSettingChange {
    <#
        .SYNOPSIS
        Validates a proposed hardware change against the host and the guest.

        .DESCRIPTION
        Pure function, so the rules that protect the host are testable without a
        hypervisor. The same 50 % memory ceiling that governs a new build governs
        a later change - a machine that is edited into swapping the host to death
        is no better than one that was built that way.

        .OUTPUTS
        IsValid, Reason, and the values that will actually be applied.
    #>
    [CmdletBinding()]
    [OutputType([psobject])]
    param(
        [Parameter(Mandatory)][psobject]$HostProfile,
        [Parameter(Mandatory)][psobject]$Machine,
        [int]$RamMB,
        [int]$Cpus,
        [int]$VramMB,
        [int]$MinimumRamMB = 1024
    )

    $result = [pscustomobject]@{
        IsValid  = $false
        Reason   = ''
        RamMB    = if ($RamMB) { $RamMB } else { [int]$Machine.RamMB }
        Cpus     = if ($Cpus) { $Cpus } else { [int]$Machine.Cpus }
        VramMB   = if ($VramMB) { $VramMB } else { [int]$Machine.VramMB }
        Warnings = @()
    }

    if ($Machine.State -ne 'poweroff' -and $Machine.State -ne 'aborted') {
        $result.Reason = 'Shut the machine down before changing its hardware.'
        return $result
    }

    $hostMB = [int]([double]$HostProfile.TotalRAM_GB * 1024)
    $ceiling = [int]([math]::Floor($hostMB * 0.50 / 4) * 4)

    if ($result.RamMB -lt $MinimumRamMB) {
        $result.Reason = "The machine needs at least $MinimumRamMB MB of memory to start."
        return $result
    }
    if ($result.RamMB -gt $ceiling) {
        $result.Reason = "That is more than half of this computer's memory. The most AutoVM will give a machine is $ceiling MB."
        return $result
    }
    if ($result.Cpus -lt 1 -or $result.Cpus -gt [int]$HostProfile.LogicalCores) {
        $result.Reason = "Choose between 1 and $($HostProfile.LogicalCores) processors."
        return $result
    }
    if ($result.VramMB -lt 16 -or $result.VramMB -gt 256) {
        $result.Reason = 'Video memory must be between 16 and 256 MB.'
        return $result
    }

    $warnings = [System.Collections.Generic.List[string]]::new()
    if ($result.RamMB -gt $hostMB * 0.45) {
        $warnings.Add('This is close to half the memory in this computer. Close other applications before starting the machine.')
    }
    if ($result.Cpus -gt [math]::Floor([int]$HostProfile.LogicalCores / 2)) {
        $warnings.Add('Giving the machine more than half the processors can make Windows itself feel slow.')
    }
    $result.Warnings = $warnings.ToArray()
    $result.IsValid = $true
    return $result
}

function Set-AutoVMMachineSetting {
    <#
        .SYNOPSIS
        Applies validated hardware changes to a powered-off machine.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][psobject]$Change,
        [ValidateSet('bidirectional', 'hosttoguest', 'guesttohost', 'disabled')][string]$Clipboard
    )

    if (-not $Change.IsValid) { throw $Change.Reason }
    if (-not $PSCmdlet.ShouldProcess($Name, 'change hardware settings')) { return }

    $args = @('modifyvm', $Name,
        '--memory', "$($Change.RamMB)",
        '--cpus', "$($Change.Cpus)",
        '--vram', "$($Change.VramMB)")
    if ($Clipboard) { $args += @('--clipboard-mode', $Clipboard) }

    Invoke-VBoxManage -Arguments $args | Out-Null
    Write-AutoVMLog -Level Success -Message (
        "'{0}' updated: {1} MB memory, {2} processors, {3} MB video memory" -f
        $Name, $Change.RamMB, $Change.Cpus, $Change.VramMB)
}

function Start-AutoVMMachine {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Name,
        [ValidateSet('gui', 'headless')][string]$Mode = 'gui'
    )
    Write-AutoVMLog -Level Info -Message "Starting '$Name'"
    Invoke-VBoxManage -Arguments @('startvm', $Name, '--type', $Mode) -TimeoutSeconds 120 | Out-Null
}

function Stop-AutoVMMachine {
    <#
        .SYNOPSIS
        Shuts a machine down.

        .PARAMETER Mode
        shutdown  ask the guest to shut down cleanly (the safe default)
        save      freeze it to disk and restore it exactly as it was
        poweroff  pull the plug - data written but not flushed is lost
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string]$Name,
        [ValidateSet('shutdown', 'save', 'poweroff')][string]$Mode = 'shutdown'
    )

    $verb = switch ($Mode) {
        'shutdown' { 'acpipowerbutton' }
        'save' { 'savestate' }
        'poweroff' { 'poweroff' }
    }
    if (-not $PSCmdlet.ShouldProcess($Name, $Mode)) { return }
    Write-AutoVMLog -Level Info -Message "$Mode on '$Name'"
    Invoke-VBoxManage -Arguments @('controlvm', $Name, $verb) -IgnoreExitCode -TimeoutSeconds 120 | Out-Null
}

function Test-AutoVMSnapshotName {
    <#
        .SYNOPSIS
        Validates a snapshot name before it reaches the command line.
    #>
    [CmdletBinding()]
    [OutputType([psobject])]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Name)

    if ([string]::IsNullOrWhiteSpace($Name)) {
        return [pscustomobject]@{ IsValid = $false; Reason = 'Give the restore point a name.' }
    }
    if ($Name.Length -gt 64) {
        return [pscustomobject]@{ IsValid = $false; Reason = 'Keep the name under 64 characters.' }
    }
    if ($Name -match '["`$]' -or $Name -match '[\x00-\x1f]') {
        return [pscustomobject]@{ IsValid = $false; Reason = 'Quotes, backticks and control characters are not allowed in a name.' }
    }
    return [pscustomobject]@{ IsValid = $true; Reason = '' }
}

function Get-AutoVMSnapshot {
    <#
        .SYNOPSIS
        Lists a machine's restore points, newest last.
    #>
    [CmdletBinding()]
    [OutputType([psobject[]])]
    param([Parameter(Mandatory)][string]$Name)

    try {
        $result = Invoke-VBoxManage -Arguments @('snapshot', $Name, 'list', '--machinereadable') `
            -IgnoreExitCode -TimeoutSeconds 60
        return @(ConvertFrom-AutoVMSnapshotList -Lines $result.Lines)
    } catch {
        return @()
    }
}

function ConvertFrom-AutoVMSnapshotList {
    <#
        .SYNOPSIS
        Parses 'snapshot list --machinereadable' output. Pure, so it is testable.
    #>
    [CmdletBinding()]
    [OutputType([psobject[]])]
    param([Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Lines)

    $byId = [ordered]@{}
    foreach ($line in $Lines) {
        if ($line -notmatch '^(?<key>SnapshotName|SnapshotUUID|SnapshotDescription)(?<path>[-0-9]*)="?(?<value>[^"]*)"?$') { continue }
        $id = if ($Matches['path']) { $Matches['path'] } else { '' }
        if (-not $byId.Contains($id)) {
            $byId[$id] = [pscustomobject]@{ Name = ''; Uuid = ''; Description = ''; Depth = ($id -split '-').Count - 1 }
        }
        switch ($Matches['key']) {
            'SnapshotName' { $byId[$id].Name = $Matches['value'] }
            'SnapshotUUID' { $byId[$id].Uuid = $Matches['value'] }
            'SnapshotDescription' { $byId[$id].Description = $Matches['value'] }
        }
    }
    return @($byId.Values | Where-Object { $_.Name })
}

function New-AutoVMSnapshot {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$SnapshotName,
        [string]$Description = ''
    )

    $check = Test-AutoVMSnapshotName -Name $SnapshotName
    if (-not $check.IsValid) { throw $check.Reason }

    $args = @('snapshot', $Name, 'take', $SnapshotName)
    if ($Description) { $args += @('--description', $Description) }
    Invoke-VBoxManage -Arguments $args -TimeoutSeconds 300 | Out-Null
    Write-AutoVMLog -Level Success -Message "Restore point '$SnapshotName' created for '$Name'"
}

function Restore-AutoVMSnapshot {
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$SnapshotName
    )

    if (-not $PSCmdlet.ShouldProcess($Name, "restore '$SnapshotName' and discard later changes")) { return }
    Invoke-VBoxManage -Arguments @('controlvm', $Name, 'poweroff') -IgnoreExitCode | Out-Null
    Start-Sleep -Seconds 3
    Invoke-VBoxManage -Arguments @('snapshot', $Name, 'restore', $SnapshotName) -TimeoutSeconds 300 | Out-Null
    Write-AutoVMLog -Level Success -Message "'$Name' restored to '$SnapshotName'"
}

function Remove-AutoVMSnapshot {
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$SnapshotName
    )

    if (-not $PSCmdlet.ShouldProcess($Name, "delete restore point '$SnapshotName'")) { return }
    Invoke-VBoxManage -Arguments @('snapshot', $Name, 'delete', $SnapshotName) -TimeoutSeconds 600 | Out-Null
    Write-AutoVMLog -Level Success -Message "Restore point '$SnapshotName' deleted"
}

function Test-AutoVMSharedFolderName {
    <#  A share name crosses into the guest, so keep it boring.  #>
    [CmdletBinding()]
    [OutputType([psobject])]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Name)

    if ([string]::IsNullOrWhiteSpace($Name)) {
        return [pscustomobject]@{ IsValid = $false; Reason = 'Give the shared folder a name.' }
    }
    if ($Name -notmatch '^[A-Za-z0-9][A-Za-z0-9_-]{0,31}$') {
        return [pscustomobject]@{ IsValid = $false; Reason = 'Use letters, digits, hyphen and underscore only, up to 32 characters.' }
    }
    return [pscustomobject]@{ IsValid = $true; Reason = '' }
}

function Get-AutoVMSharedFolder {
    [CmdletBinding()]
    [OutputType([psobject[]])]
    param([Parameter(Mandatory)][string]$Name)

    try {
        $result = Invoke-VBoxManage -Arguments @('showvminfo', $Name, '--machinereadable') `
            -IgnoreExitCode -TimeoutSeconds 60
        $shares = [ordered]@{}
        foreach ($line in $result.Lines) {
            if ($line -match '^SharedFolderNameMachineMapping(?<n>\d+)="(?<v>.*)"$') {
                $key = $Matches['n']
                if (-not $shares.Contains($key)) { $shares[$key] = [pscustomobject]@{ Name = ''; Path = '' } }
                $shares[$key].Name = $Matches['v']
            }
            if ($line -match '^SharedFolderPathMachineMapping(?<n>\d+)="(?<v>.*)"$') {
                $key = $Matches['n']
                if (-not $shares.Contains($key)) { $shares[$key] = [pscustomobject]@{ Name = ''; Path = '' } }
                $shares[$key].Path = $Matches['v']
            }
        }
        return @($shares.Values)
    } catch {
        return @()
    }
}

function Add-AutoVMSharedFolder {
    <#
        .SYNOPSIS
        Shares a Windows folder with the guest so files can be moved in and out.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$ShareName,
        [Parameter(Mandatory)][string]$Path,
        [switch]$ReadOnly
    )

    $check = Test-AutoVMSharedFolderName -Name $ShareName
    if (-not $check.IsValid) { throw $check.Reason }
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) { throw "There is no folder at $Path." }

    $args = @('sharedfolder', 'add', $Name, '--name', $ShareName, '--hostpath', $Path, '--automount')
    if ($ReadOnly) { $args += '--readonly' }
    Invoke-VBoxManage -Arguments $args | Out-Null
    Write-AutoVMLog -Level Success -Message "Shared '$Path' with '$Name' as '$ShareName'"
}

function Remove-AutoVMSharedFolder {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$ShareName
    )
    if (-not $PSCmdlet.ShouldProcess($Name, "stop sharing '$ShareName'")) { return }
    Invoke-VBoxManage -Arguments @('sharedfolder', 'remove', $Name, '--name', $ShareName) -IgnoreExitCode | Out-Null
}

function Export-AutoVMMachine {
    <#
        .SYNOPSIS
        Exports a powered-off machine to a single .ova file for backup or transfer.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Path
    )

    if ([System.IO.Path]::GetExtension($Path) -ne '.ova') { $Path = "$Path.ova" }
    $folder = Split-Path -Parent $Path
    if ($folder -and -not (Test-Path -LiteralPath $folder)) {
        New-Item -ItemType Directory -Force -Path $folder | Out-Null
    }
    Write-AutoVMLog -Level Step -Message "Exporting '$Name' to $Path. This takes a while."
    Invoke-VBoxManage -Arguments @('export', $Name, '--output', $Path) -TimeoutSeconds 7200 | Out-Null
    Write-AutoVMLog -Level Success -Message "Exported to $Path"
    return $Path
}

function Remove-AutoVMMachine {
    <#
        .SYNOPSIS
        Deletes a machine and its disk. Requires the machine's own name as confirmation.

        .PARAMETER Confirmation
        Must equal the machine name exactly. Typing the name is the consent -
        there is no yes/no prompt for something this final.
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Confirmation
    )

    if ($Confirmation -cne $Name) {
        throw "To delete '$Name', type its name exactly. Nothing has been deleted."
    }
    if (-not $PSCmdlet.ShouldProcess($Name, 'delete the machine and its disk')) { return }

    Invoke-VBoxManage -Arguments @('controlvm', $Name, 'poweroff') -IgnoreExitCode | Out-Null
    Start-Sleep -Seconds 2
    Invoke-VBoxManage -Arguments @('unregistervm', $Name, '--delete') -TimeoutSeconds 600 | Out-Null
    Write-AutoVMLog -Level Warn -Message "'$Name' and its disk have been deleted."
}
