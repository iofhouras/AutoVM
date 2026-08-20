<#
    Handover: the surface the user is left with once the build is done.

    A correctly built machine that its owner cannot start has failed just as
    completely as one that never booted, so this phase is treated as a
    deliverable rather than a courtesy.
#>

function New-AutoVMControlCenter {
    <#
        .SYNOPSIS
        Writes the control panel script and its silent launcher.

        .OUTPUTS
        The paths of the generated script and launcher.
    #>
    [CmdletBinding()]
    [OutputType([psobject])]
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$VMName,
        [Parameter(Mandatory)][string]$GuestName,
        [Parameter(Mandatory)][string]$UserName,
        [string]$SnapshotName = 'clean-baseline'
    )

    $appDir = Join-Path $Root 'app'
    if (-not (Test-Path -LiteralPath $appDir)) { New-Item -ItemType Directory -Force -Path $appDir | Out-Null }

    $templateDir = Join-Path $script:AutoVMModuleRoot 'Templates'

    $script = (Get-Content -LiteralPath (Join-Path $templateDir 'ControlCenter.ps1.template') -Raw).
    Replace('{{VMNAME}}', $VMName).
    Replace('{{GUESTNAME}}', $GuestName).
    Replace('{{USERNAME}}', $UserName).
    Replace('{{SNAPSHOT}}', $SnapshotName)

    $scriptPath = Join-Path $appDir 'AutoVMControlCenter.ps1'
    Set-Content -LiteralPath $scriptPath -Value $script -Encoding utf8

    $launcher = (Get-Content -LiteralPath (Join-Path $templateDir 'launch.vbs.template') -Raw).
    Replace('{{SCRIPTPATH}}', $scriptPath)

    $launcherPath = Join-Path $appDir 'launch.vbs'
    Set-Content -LiteralPath $launcherPath -Value $launcher -Encoding ascii

    Write-AutoVMLog -Level Info -Message "Control panel written to $scriptPath"
    return [pscustomobject]@{ ScriptPath = $scriptPath; LauncherPath = $launcherPath }
}

function New-AutoVMShortcut {
    <#
        .SYNOPSIS
        Creates the desktop (and optionally Start menu) shortcut.

        .DESCRIPTION
        The desktop path is resolved through the shell rather than assembled
        from the user profile, so it still lands on the desktop when the folder
        has been redirected into OneDrive.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$LauncherPath,
        [string]$Name = 'AutoVM Control Center',
        [string]$Description = 'Start, configure and shut down your virtual machine',
        [string]$IconPath,
        [switch]$IncludeStartMenu
    )

    $desktop = [Environment]::GetFolderPath('Desktop')
    $targets = @(Join-Path $desktop "$Name.lnk")

    if ($IncludeStartMenu) {
        $programs = [Environment]::GetFolderPath('Programs')
        if ($programs) { $targets += (Join-Path $programs "$Name.lnk") }
    }

    if (-not $IconPath) {
        try {
            $vbox = (Get-ItemProperty 'HKLM:\SOFTWARE\Oracle\VirtualBox' -ErrorAction Stop).InstallDir
            $IconPath = (Join-Path $vbox 'VirtualBox.exe') + ',0'
        } catch { $IconPath = "$env:SystemRoot\System32\shell32.dll,15" }
    }

    $shell = New-Object -ComObject WScript.Shell
    foreach ($target in $targets) {
        $link = $shell.CreateShortcut($target)
        $link.TargetPath = "$env:SystemRoot\System32\wscript.exe"
        $link.Arguments = '"{0}"' -f $LauncherPath
        $link.WorkingDirectory = Split-Path -Parent $LauncherPath
        $link.IconLocation = $IconPath
        $link.Description = $Description
        $link.WindowStyle = 1
        $link.Save()
    }

    $primary = $targets[0]
    if (-not (Test-Path -LiteralPath $primary)) {
        throw "AUTOVM-P7: The desktop shortcut could not be created at $primary."
    }

    Write-AutoVMLog -Level Success -Message "Desktop shortcut created: $primary"
    return $primary
}

function New-AutoVMHandoverNote {
    <#
        .SYNOPSIS
        The plain-language summary the user is left with, on screen and on disk.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][psobject]$Plan,
        [Parameter(Mandatory)][string]$UserName,
        [Parameter(Mandatory)][string]$ShortcutPath,
        [string]$SnapshotName = 'clean-baseline',
        [string[]]$Destroyed = @()
    )

    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add("Your $($Plan.GuestName) virtual machine is ready.")
    $lines.Add('')
    $lines.Add("Start it        Double-click '$(Split-Path -Leaf $ShortcutPath)' on your desktop, then Start (Window).")
    $lines.Add("Sign in as      $UserName  - exactly as typed. Linux logins are case-sensitive.")
    $lines.Add("Password        the one you chose during setup. AutoVM did not keep a copy.")
    $lines.Add("Shut it down    Use Shut Down in the control panel, or shut down from inside the guest.")
    $lines.Add("Undo changes    Restore to first-boot state returns the machine to '$SnapshotName' and discards")
    $lines.Add("                everything saved inside it since the build.")
    $lines.Add('')
    $lines.Add("Memory          The machine uses $($Plan.RamMB) MB, about $($Plan.HostRamShare)% of this device.")
    $lines.Add("                Close large applications before starting it.")
    $lines.Add("Network         Outbound only. Nothing on your network can reach into the guest, which is why a")
    $lines.Add("                simple password is acceptable. Change it first if you ever switch the machine to")
    $lines.Add("                bridged networking or forward a port into it.")

    if ($Destroyed.Count -gt 0) {
        $lines.Add('')
        $lines.Add("Removed during setup, with your confirmation:")
        foreach ($item in $Destroyed) { $lines.Add("  - $item") }
    }

    return ($lines -join [Environment]::NewLine)
}
