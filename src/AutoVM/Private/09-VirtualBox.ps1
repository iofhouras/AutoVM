<#
    The VirtualBox driver.

    Every call to VBoxManage goes through Invoke-VBoxManage so that output,
    exit codes and failures are logged and redacted consistently. VBoxManage
    emits text rather than objects, so the parsers here are deliberately narrow
    and always use --machinereadable where a machine-readable form exists.
#>

$script:AutoVMVBoxManage = $null

function Get-AutoVMVBoxManage {
    <#
        .SYNOPSIS
        Resolves VBoxManage.exe, refreshing the session PATH first.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([switch]$Force)

    if ($script:AutoVMVBoxManage -and -not $Force -and (Test-Path -LiteralPath $script:AutoVMVBoxManage)) {
        return $script:AutoVMVBoxManage
    }

    Update-AutoVMSessionPath

    $candidates = @()
    try {
        $key = Get-ItemProperty 'HKLM:\SOFTWARE\Oracle\VirtualBox' -ErrorAction Stop
        if ($key.InstallDir) { $candidates += (Join-Path $key.InstallDir 'VBoxManage.exe') }
    } catch { }

    if ($env:VBOX_MSI_INSTALL_PATH) { $candidates += (Join-Path $env:VBOX_MSI_INSTALL_PATH 'VBoxManage.exe') }
    if ($env:ProgramFiles) { $candidates += (Join-Path $env:ProgramFiles 'Oracle\VirtualBox\VBoxManage.exe') }

    $onPath = Get-Command 'VBoxManage.exe' -ErrorAction SilentlyContinue
    if ($onPath) { $candidates += $onPath.Source }

    foreach ($candidate in $candidates) {
        if ($candidate -and (Test-Path -LiteralPath $candidate)) {
            $script:AutoVMVBoxManage = $candidate
            return $candidate
        }
    }
    return $null
}

function Invoke-VBoxManage {
    <#
        .SYNOPSIS
        Runs VBoxManage and returns its output.

        .PARAMETER Arguments
        Argument array, passed without shell interpretation.

        .PARAMETER IgnoreExitCode
        Some subcommands write to stderr and return non-zero on entirely normal
        paths; those callers test the output instead.
    #>
    [CmdletBinding()]
    [OutputType([psobject])]
    param(
        [Parameter(Mandatory)][string[]]$Arguments,
        [switch]$IgnoreExitCode,
        [int]$TimeoutSeconds = 0
    )

    $exe = Get-AutoVMVBoxManage
    if (-not $exe) { throw 'AUTOVM-P3: VBoxManage.exe could not be found. VirtualBox is not installed, or the install did not complete.' }

    Write-AutoVMLog -Level Debug -Message ("VBoxManage {0}" -f ((Protect-AutoVMString ($Arguments -join ' '))))

    $stdout = [System.IO.Path]::GetTempFileName()
    $stderr = [System.IO.Path]::GetTempFileName()
    try {
        $proc = Start-Process -FilePath $exe -ArgumentList $Arguments -NoNewWindow -PassThru `
            -RedirectStandardOutput $stdout -RedirectStandardError $stderr

        if ($TimeoutSeconds -gt 0) {
            if (-not $proc.WaitForExit($TimeoutSeconds * 1000)) {
                try { $proc.Kill() } catch { }
                throw "VBoxManage $($Arguments[0]) did not return within $TimeoutSeconds seconds."
            }
        } else {
            $proc.WaitForExit()
        }

        $out = (Get-Content -LiteralPath $stdout -Raw -ErrorAction SilentlyContinue)
        $err = (Get-Content -LiteralPath $stderr -Raw -ErrorAction SilentlyContinue)
        $code = $proc.ExitCode

        if ($code -ne 0 -and -not $IgnoreExitCode) {
            $detail = (@($err, $out) | Where-Object { $_ } | ForEach-Object { $_.Trim() }) -join ' | '
            throw "VBoxManage $($Arguments[0]) failed (exit $code): $detail"
        }

        return [pscustomobject]@{
            ExitCode = $code
            Output   = if ($out) { $out } else { '' }
            Error    = if ($err) { $err } else { '' }
            Lines    = @(if ($out) { $out -split "`r?`n" } else { @() })
        }
    } finally {
        Remove-Item -LiteralPath $stdout, $stderr -Force -ErrorAction SilentlyContinue
    }
}

function Get-AutoVMVirtualBoxVersion {
    [CmdletBinding()]
    [OutputType([string])]
    param()

    if (-not (Get-AutoVMVBoxManage)) { return $null }
    try {
        $result = Invoke-VBoxManage -Arguments @('--version') -TimeoutSeconds 60
        return ($result.Output.Trim() -split "`r?`n")[0]
    } catch {
        return $null
    }
}

function Install-AutoVMVirtualBox {
    <#
        .SYNOPSIS
        Installs VirtualBox (and 7-Zip) with winget, at most twice.

        .DESCRIPTION
        This is the step most likely to fail on a managed device: VirtualBox
        installs kernel-mode drivers, and device-management policy can refuse
        them. AutoVM reports that refusal as an environment problem rather than
        trying to work around driver signing - working around it would weaken
        the machine the user asked to protect.
    #>
    [CmdletBinding()]
    param([int]$MaxAttempts = 2)

    if (-not (Get-Command 'winget.exe' -ErrorAction SilentlyContinue)) {
        throw 'AUTOVM-P3: winget is not available on this device, so AutoVM cannot install VirtualBox automatically. Install VirtualBox 7.x manually and run AutoVM again.'
    }

    foreach ($package in @('Oracle.VirtualBox', '7zip.7zip')) {
        for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
            Write-AutoVMLog -Level Step -Message "Installing $package (attempt $attempt of $MaxAttempts)" -Percent 20

            $args = @('install', '--exact', '--id', $package, '--silent',
                '--accept-package-agreements', '--accept-source-agreements')
            $proc = Start-Process -FilePath 'winget.exe' -ArgumentList $args -NoNewWindow -PassThru -Wait

            # 0 success; -1978335189 already installed / no applicable update.
            if ($proc.ExitCode -eq 0 -or $proc.ExitCode -eq -1978335189) {
                Write-AutoVMLog -Level Success -Message "$package is present"
                break
            }
            if ($attempt -eq $MaxAttempts) {
                if ($package -eq 'Oracle.VirtualBox') {
                    throw ("AUTOVM-P3: VirtualBox could not be installed (winget exit {0}). " -f $proc.ExitCode) +
                    'On a company-managed device this usually means policy is blocking the installation of kernel drivers. ' +
                    'AutoVM will not disable driver signing or any other protection to get around that. Ask whoever manages the device to allow Oracle VirtualBox, then run AutoVM again.'
                }
                Write-AutoVMLog -Level Warn -Message "$package could not be installed (exit $($proc.ExitCode)). Continuing without it."
            }
        }
    }

    Update-AutoVMSessionPath
    $version = Get-AutoVMVirtualBoxVersion
    if (-not $version) {
        throw 'AUTOVM-P3: VirtualBox reported success but VBoxManage.exe is still missing. A restart may be required before AutoVM can continue.'
    }
    Write-AutoVMLog -Level Success -Message "VirtualBox $version is ready"
    return $version
}

function Get-AutoVMVmName {
    <#  Registered VM names.  #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param()

    try {
        $result = Invoke-VBoxManage -Arguments @('list', 'vms') -TimeoutSeconds 60 -IgnoreExitCode
        return @($result.Lines | ForEach-Object {
                if ($_ -match '^"(?<name>.*)"\s+\{') { $Matches['name'] }
            })
    } catch {
        return @()
    }
}

function Get-AutoVMVmProperty {
    <#  Reads one key from showvminfo --machinereadable.  #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$VMName,
        [Parameter(Mandatory)][string]$Key
    )

    try {
        $result = Invoke-VBoxManage -Arguments @('showvminfo', $VMName, '--machinereadable') -TimeoutSeconds 60 -IgnoreExitCode
        foreach ($line in $result.Lines) {
            if ($line -match "^$([regex]::Escape($Key))=(.*)$") {
                return $Matches[1].Trim('"')
            }
        }
    } catch { }
    return $null
}

function Get-AutoVMGuestProperty {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$VMName,
        [Parameter(Mandatory)][string]$Name
    )

    try {
        $result = Invoke-VBoxManage -Arguments @('guestproperty', 'get', $VMName, $Name) -TimeoutSeconds 60 -IgnoreExitCode
        if ($result.Output -match 'Value:\s*(?<value>.+)') { return $Matches['value'].Trim() }
    } catch { }
    return $null
}

function New-AutoVMVirtualMachine {
    <#
        .SYNOPSIS
        Creates and configures the machine, its disk and its controllers.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][psobject]$Plan,
        [Parameter(Mandatory)][string]$IsoPath
    )

    $vm = $Plan.VMName

    if ($Plan.MachineFolder) {
        if (-not (Test-Path -LiteralPath $Plan.MachineFolder)) {
            New-Item -ItemType Directory -Force -Path $Plan.MachineFolder | Out-Null
        }
        Invoke-VBoxManage -Arguments @('setproperty', 'machinefolder', $Plan.MachineFolder) | Out-Null
        Write-AutoVMLog -Level Info -Message "Machines will be stored in $($Plan.MachineFolder)"
    }

    if (-not $PSCmdlet.ShouldProcess($vm, 'create virtual machine')) { return }

    Write-AutoVMLog -Level Step -Message "Creating the virtual machine '$vm'" -Percent 45
    Invoke-VBoxManage -Arguments @('createvm', '--name', $vm, '--ostype', $Plan.OsType, '--register') | Out-Null

    $modify = @(
        'modifyvm', $vm,
        '--memory', "$($Plan.RamMB)",
        '--cpus', "$($Plan.Cpus)",
        '--vram', "$($Plan.VramMB)",
        '--graphicscontroller', 'vmsvga',
        '--accelerate3d', $(if ($Plan.Accelerate3D) { 'on' } else { 'off' }),
        '--firmware', $Plan.Firmware,
        '--ioapic', 'on',
        '--rtcuseutc', 'on',
        '--nested-hw-virt', 'off',
        '--paravirtprovider', 'kvm',
        '--audio-driver', $(if ($Plan.Audio) { 'default' } else { 'none' }),
        '--clipboard-mode', 'bidirectional',
        '--draganddrop', 'bidirectional',
        '--nic1', 'nat',
        '--nictype1', 'virtio',
        '--boot1', 'dvd', '--boot2', 'disk', '--boot3', 'none', '--boot4', 'none',
        '--description', "Built by AutoVM on $(Get-Date -Format 'yyyy-MM-dd')"
    )
    Invoke-VBoxManage -Arguments $modify | Out-Null

    $cfgFile = Get-AutoVMVmProperty -VMName $vm -Key 'CfgFile'
    if (-not $cfgFile) { throw "AUTOVM-P5: '$vm' was created but VirtualBox does not report a configuration file for it." }
    $vmDir = Split-Path -Parent $cfgFile
    $vdi = Join-Path $vmDir "$vm.vdi"

    Write-AutoVMLog -Level Info -Message "Creating a $($Plan.DiskGB) GB dynamic disk"
    Invoke-VBoxManage -Arguments @('createmedium', 'disk', '--filename', $vdi,
        '--size', "$([int]$Plan.DiskGB * 1024)", '--variant', 'Standard') | Out-Null

    Invoke-VBoxManage -Arguments @('storagectl', $vm, '--name', 'SATA', '--add', 'sata',
        '--controller', 'IntelAhci', '--portcount', '2') | Out-Null

    Invoke-VBoxManage -Arguments @('storageattach', $vm, '--storagectl', 'SATA', '--port', '0',
        '--device', '0', '--type', 'hdd', '--medium', $vdi, '--nonrotational', 'on', '--discard', 'on') | Out-Null

    Invoke-VBoxManage -Arguments @('storageattach', $vm, '--storagectl', 'SATA', '--port', '1',
        '--device', '0', '--type', 'dvddrive', '--medium', $IsoPath) | Out-Null

    Write-AutoVMLog -Level Success -Message "'$vm' created in $vmDir"
    return [pscustomobject]@{ VMName = $vm; Directory = $vmDir; DiskPath = $vdi }
}

function Start-AutoVMUnattendedInstall {
    <#
        .SYNOPSIS
        Hands the machine to VirtualBox's unattended installer and starts it.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][psobject]$Plan,
        [Parameter(Mandatory)][string]$IsoPath,
        [Parameter(Mandatory)][string]$PreseedPath,
        [Parameter(Mandatory)][psobject]$CredentialPlan,
        [string]$HostName = 'autovm',
        [switch]$Headless
    )

    $plain = ConvertFrom-AutoVMSecureString -Secure $CredentialPlan.Password
    try {
        Register-AutoVMSecret -Value $plain

        # --hostname must be qualified or VirtualBox rejects it outright.
        $fqdn = if ($HostName -match '\.') { $HostName } else { "$HostName.local" }

        $args = @(
            'unattended', 'install', $Plan.VMName,
            "--iso=$IsoPath",
            "--user=$($CredentialPlan.InstallerName)",
            "--password=$plain",
            "--full-user-name=$($CredentialPlan.FullName)",
            "--hostname=$fqdn",
            '--locale=en_US', '--country=US', '--time-zone=UTC',
            "--script-template=$PreseedPath",
            '--install-additions',
            $(if ($Headless) { '--start-vm=headless' } else { '--start-vm=gui' })
        )

        Write-AutoVMLog -Level Step -Message 'Starting the unattended installation' -Percent 50
        Invoke-VBoxManage -Arguments $args -TimeoutSeconds 300 | Out-Null
        Write-AutoVMLog -Level Info -Message 'The installer is running. This is the long part of the build.'
    } finally {
        $plain = $null
    }
}

function Wait-AutoVMInstall {
    <#
        .SYNOPSIS
        Polls the guest until it reports its operating system, or the deadline passes.

        .DESCRIPTION
        Long stretches with no change are normal - the package upgrade inside
        the installer accounts for most of the run. A machine that stays
        'running' with no guest properties at the deadline is almost always
        waiting on a dialog, so a screenshot is captured for diagnosis rather
        than guessing.
    #>
    [CmdletBinding()]
    [OutputType([psobject])]
    param(
        [Parameter(Mandatory)][string]$VMName,
        [int]$TimeoutMinutes = 90,
        [int]$PollSeconds = 30,
        [string]$ScreenshotDirectory
    )

    $deadline = (Get-Date).AddMinutes($TimeoutMinutes)
    $started = Get-Date
    $seenPowerOff = $false

    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Seconds $PollSeconds

        $state = Get-AutoVMVmProperty -VMName $VMName -Key 'VMState'
        $product = Get-AutoVMGuestProperty -VMName $VMName -Name '/VirtualBox/GuestInfo/OS/Product'
        $elapsed = (Get-Date) - $started

        $percent = [math]::Min(95, 50 + [int](45 * $elapsed.TotalMinutes / [math]::Max(1, $TimeoutMinutes)))
        Write-AutoVMLog -Level Step -Percent $percent -Message (
            'Installing - {0:hh\:mm\:ss} elapsed, machine is {1}{2}' -f $elapsed, $state,
            $(if ($product) { ", guest reports $product" } else { '' })
        )

        if ($state -eq 'poweroff') {
            if (-not $seenPowerOff) {
                # The post-install reboot shows up as a brief power-off.
                $seenPowerOff = $true
                Write-AutoVMLog -Level Info -Message 'The guest restarted after installing.'
            }
        }
        if ($state -eq 'aborted') {
            return [pscustomobject]@{ Completed = $false; Reason = 'The virtual machine stopped unexpectedly, which usually means the host ran out of memory.'; State = $state }
        }
        if ($product -and $product -match 'Linux') {
            return [pscustomobject]@{ Completed = $true; Reason = ''; State = $state; Product = $product; Elapsed = $elapsed }
        }
    }

    $shot = $null
    if ($ScreenshotDirectory) {
        $shot = Save-AutoVMScreenshot -VMName $VMName -Directory $ScreenshotDirectory
    }
    return [pscustomobject]@{
        Completed  = $false
        Reason     = "The installation did not finish within $TimeoutMinutes minutes. The installer is most likely waiting for an answer on screen."
        Screenshot = $shot
    }
}

function Save-AutoVMScreenshot {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$VMName,
        [Parameter(Mandatory)][string]$Directory
    )

    if (-not (Test-Path -LiteralPath $Directory)) { New-Item -ItemType Directory -Force -Path $Directory | Out-Null }
    $path = Join-Path $Directory ("screen-{0}.png" -f (Get-Date -Format 'HHmmss'))
    try {
        Invoke-VBoxManage -Arguments @('controlvm', $VMName, 'screenshotpng', $path) -IgnoreExitCode | Out-Null
        if (Test-Path -LiteralPath $path) {
            Write-AutoVMLog -Level Info -Message "Captured what the guest is showing: $path"
            return $path
        }
    } catch { }
    return $null
}

function Dismount-AutoVMInstaller {
    <#  Detaches the installer image and boots from disk from now on.  #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$VMName)

    Invoke-VBoxManage -Arguments @('storageattach', $VMName, '--storagectl', 'SATA',
        '--port', '1', '--device', '0', '--medium', 'emptydrive') -IgnoreExitCode | Out-Null
    Invoke-VBoxManage -Arguments @('modifyvm', $VMName, '--boot1', 'disk', '--boot2', 'none') -IgnoreExitCode | Out-Null
    Write-AutoVMLog -Level Info -Message 'Installer media detached; the guest now boots from its own disk.'
}

function Test-AutoVMGuestLogin {
    <#
        .SYNOPSIS
        Proves the account exists in the guest with the password the user chose.
    #>
    [CmdletBinding()]
    [OutputType([psobject])]
    param(
        [Parameter(Mandatory)][string]$VMName,
        [Parameter(Mandatory)][string]$UserName,
        [Parameter(Mandatory)][securestring]$Password
    )

    $plain = ConvertFrom-AutoVMSecureString -Secure $Password
    try {
        Register-AutoVMSecret -Value $plain
        $result = Invoke-VBoxManage -IgnoreExitCode -TimeoutSeconds 180 -Arguments @(
            'guestcontrol', $VMName, 'run',
            '--username', $UserName, '--password', $plain,
            '--exe', '/usr/bin/id', '--wait-stdout', '--', 'id', $UserName
        )
        $ok = $result.Output -match "uid=\d+\($([regex]::Escape($UserName))\)"
        return [pscustomobject]@{ Success = [bool]$ok; Output = $result.Output.Trim(); Error = $result.Error.Trim() }
    } catch {
        return [pscustomobject]@{ Success = $false; Output = ''; Error = $_.Exception.Message }
    } finally {
        $plain = $null
    }
}

function Repair-AutoVMGuestAccount {
    <#
        .SYNOPSIS
        Renames the lowercase account in the guest when the install-time rename did not take.

        .DESCRIPTION
        Cheaper than rebuilding: the machine is already installed, only the
        account name is wrong.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$VMName,
        [Parameter(Mandatory)][string]$InstallerName,
        [Parameter(Mandatory)][string]$TargetName,
        [Parameter(Mandatory)][securestring]$Password
    )

    $plain = ConvertFrom-AutoVMSecureString -Secure $Password
    try {
        Register-AutoVMSecret -Value $plain
        Write-AutoVMLog -Level Warn -Message "Renaming '$InstallerName' to '$TargetName' inside the guest."
        $script = "echo '$plain' | sudo -S sh -c 'usermod --badname -l $TargetName $InstallerName; usermod --badname -d /home/$TargetName -m $TargetName; chown -R ${TargetName}:${InstallerName} /home/$TargetName'"
        Invoke-VBoxManage -IgnoreExitCode -TimeoutSeconds 300 -Arguments @(
            'guestcontrol', $VMName, 'run',
            '--username', $InstallerName, '--password', $plain,
            '--exe', '/bin/sh', '--wait-stdout', '--', 'sh', '-c', $script
        ) | Out-Null
    } finally {
        $plain = $null
    }
}

function New-AutoVMBaselineSnapshot {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$VMName,
        [string]$Name = 'clean-baseline',
        [int]$ShutdownWaitSeconds = 90
    )

    $state = Get-AutoVMVmProperty -VMName $VMName -Key 'VMState'
    if ($state -ne 'poweroff') {
        Write-AutoVMLog -Level Step -Message 'Shutting the guest down cleanly before taking the restore point' -Percent 92
        Invoke-VBoxManage -Arguments @('controlvm', $VMName, 'acpipowerbutton') -IgnoreExitCode | Out-Null

        $deadline = (Get-Date).AddSeconds($ShutdownWaitSeconds)
        while ((Get-Date) -lt $deadline) {
            Start-Sleep -Seconds 5
            if ((Get-AutoVMVmProperty -VMName $VMName -Key 'VMState') -eq 'poweroff') { break }
        }
        if ((Get-AutoVMVmProperty -VMName $VMName -Key 'VMState') -ne 'poweroff') {
            Write-AutoVMLog -Level Warn -Message 'The guest did not shut down in time; stopping it before snapshotting.'
            Invoke-VBoxManage -Arguments @('controlvm', $VMName, 'poweroff') -IgnoreExitCode | Out-Null
            Start-Sleep -Seconds 5
        }
    }

    Invoke-VBoxManage -Arguments @('snapshot', $VMName, 'take', $Name,
        '--description', 'First good boot, created by AutoVM. Restoring returns the machine to this state.') | Out-Null
    Write-AutoVMLog -Level Success -Message "Restore point '$Name' created"
}

function Test-AutoVMSnapshot {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$VMName,
        [string]$Name = 'clean-baseline'
    )

    try {
        $result = Invoke-VBoxManage -Arguments @('snapshot', $VMName, 'list') -IgnoreExitCode -TimeoutSeconds 60
        return [bool]($result.Output -match [regex]::Escape($Name))
    } catch {
        return $false
    }
}
