<#
    AutoVM - desktop application.

    Four surfaces over one engine:

        Create    pick a system, type a login, press Create VM Now!
        Building  progress and a live log while the machine is built
        Ready     the handover notes
        Manage    power, hardware, restore points, shared folders, export, delete

    Anything that can take more than a moment runs in its own runspace and
    reports through a queue that a dispatcher timer drains, so the window stays
    responsive across an install that can run for an hour.
#>
[CmdletBinding()]
param(
    [switch]$NoElevate,
    [string]$ModulePath
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# ---------------------------------------------------------------- bootstrap
$appRoot = Split-Path -Parent $PSCommandPath
if (-not $ModulePath) {
    foreach ($candidate in @(
            (Join-Path $appRoot 'AutoVM\AutoVM.psd1'),
            (Join-Path $appRoot '..\AutoVM\AutoVM.psd1'),
            (Join-Path (Split-Path -Parent $appRoot) 'AutoVM\AutoVM.psd1')
        )) {
        if (Test-Path -LiteralPath $candidate) { $ModulePath = (Resolve-Path $candidate).Path; break }
    }
}
if (-not $ModulePath -or -not (Test-Path -LiteralPath $ModulePath)) {
    throw 'The AutoVM engine could not be found next to the application. Reinstall AutoVM.'
}

# WPF only runs on a single-threaded-apartment thread.
if ([System.Threading.Thread]::CurrentThread.GetApartmentState() -ne 'STA') {
    $pwsh = (Get-Command pwsh.exe -ErrorAction SilentlyContinue).Source
    if ($pwsh) {
        Start-Process -FilePath $pwsh -Verb RunAs -ArgumentList @(
            '-STA', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden',
            '-File', "`"$PSCommandPath`"", '-ModulePath', "`"$ModulePath`"", '-NoElevate')
        return
    }
    throw 'AutoVM must run on a single-threaded-apartment host. Start it with: pwsh -STA -File AutoVM.ps1'
}

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Windows.Forms
Import-Module $ModulePath -Force

function Test-Elevated {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    return ([Security.Principal.WindowsPrincipal]$id).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

# Installing a hypervisor loads a kernel driver, so elevate once, here.
if (-not (Test-Elevated) -and -not $NoElevate) {
    $shell = if (Get-Command pwsh.exe -ErrorAction SilentlyContinue) { 'pwsh.exe' } else { 'powershell.exe' }
    try {
        Start-Process -FilePath $shell -Verb RunAs -ArgumentList @(
            '-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden',
            '-File', "`"$PSCommandPath`"", '-ModulePath', "`"$ModulePath`"")
        return
    } catch {
        [System.Windows.Forms.MessageBox]::Show(
            "AutoVM needs administrator rights to install the virtualization software.`n`n" +
            "Close this window, right-click AutoVM and choose 'Run as administrator'.",
            'AutoVM', 'OK', 'Warning') | Out-Null
        return
    }
}

# ---------------------------------------------------------------- window
[xml]$xaml = Get-Content -LiteralPath (Join-Path $appRoot 'MainWindow.xaml') -Raw
$window = [Windows.Markup.XamlReader]::Load([System.Xml.XmlNodeReader]::new($xaml))

$ui = @{}
foreach ($name in @(
        'NavCreate', 'NavManage', 'SideState', 'SideDetail', 'SidebarNote', 'VersionLabel',
        'PageCreate', 'PageBuilding', 'PageReady', 'PageManage', 'BusyVeil', 'BusyText', 'BusySub',
        'CardKali', 'CardDebian', 'DotKali', 'DotDebian', 'KaliSpec', 'DebianSpec',
        'TxtUser', 'UserHint', 'TxtVmName', 'TxtPass', 'TxtPass2', 'StrengthBar', 'PassHint', 'Pass2Hint',
        'DeviceDetails', 'GateList', 'PlanLine', 'PlanSub', 'BtnCreate',
        'ProgressFill', 'BuildStatus', 'BuildClock', 'LogBox', 'LogScroller', 'BtnCancelBuild',
        'DoneTitle', 'DoneDeck', 'DoneNote', 'BtnCopyNote', 'BtnOpenLogs', 'BtnGoManage',
        'BtnRefresh', 'MachineList', 'ManageTabs',
        'OvState', 'OvLogin', 'OvGuest', 'OvHardware', 'OvDisk', 'OvIp',
        'BtnStart', 'BtnStartHeadless', 'BtnShutdown', 'BtnSaveState', 'BtnPowerOff', 'BtnVBoxGui',
        'SettingsLocked', 'SettingsLockedText', 'SetRam', 'SetCpus', 'SetVram', 'SetClipboard',
        'RamHint', 'CpuHint', 'BtnApplySettings', 'SettingsMsg',
        'SnapshotList', 'TxtSnapshotName', 'BtnTakeSnapshot', 'BtnRestoreSnapshot', 'BtnDeleteSnapshot',
        'ShareList', 'TxtShareName', 'TxtSharePath', 'BtnPickFolder', 'ChkShareReadOnly',
        'BtnAddShare', 'BtnRemoveShare', 'ShareMsg',
        'BtnOpenVmFolder', 'BtnExport', 'TxtDeleteConfirm', 'BtnDeleteVm', 'DeleteHint'
    )) {
    $ui[$name] = $window.FindName($name)
}

$app = [ordered]@{
    Page        = 'Create'
    Guest       = 'kali'
    HostProfile = $null
    Gates       = @()
    Verdict     = $null
    Plan        = $null
    Report      = $null
    Machines    = @()
    Selected    = $null
    Snapshots   = @()
    Shares      = @()
    LoginName   = ''
    Started     = $null
    Running     = $false
    Queue       = [System.Collections.Concurrent.ConcurrentQueue[psobject]]::new()
    Runspace    = $null
    Shell       = $null
}

function Set-Brush { param($Element, [string]$Property, [string]$Hex)
    $Element.$Property = [Windows.Media.BrushConverter]::new().ConvertFromString($Hex) }

function Show-Message { param([string]$Text, [string]$Title = 'AutoVM', [string]$Icon = 'Information')
    [System.Windows.MessageBox]::Show($Text, $Title, 'OK', $Icon) | Out-Null }

function Confirm-Action { param([string]$Text, [string]$Title = 'AutoVM')
    return ([System.Windows.MessageBox]::Show($Text, $Title, 'YesNo', 'Warning') -eq 'Yes') }

# ---------------------------------------------------------------- navigation
function Show-Page {
    param([ValidateSet('Create', 'Building', 'Ready', 'Manage')][string]$Name)

    $app.Page = $Name
    $ui.PageCreate.Visibility = if ($Name -eq 'Create') { 'Visible' } else { 'Collapsed' }
    $ui.PageBuilding.Visibility = if ($Name -eq 'Building') { 'Visible' } else { 'Collapsed' }
    $ui.PageReady.Visibility = if ($Name -eq 'Ready') { 'Visible' } else { 'Collapsed' }
    $ui.PageManage.Visibility = if ($Name -eq 'Manage') { 'Visible' } else { 'Collapsed' }

    foreach ($pair in @(@{ b = $ui.NavCreate; on = ($Name -eq 'Create') },
            @{ b = $ui.NavManage; on = ($Name -eq 'Manage') })) {
        Set-Brush $pair.b 'Background' $(if ($pair.on) { '#1E2C4E' } else { '#18213C' })
        Set-Brush $pair.b 'BorderBrush' $(if ($pair.on) { '#3E8BFF' } else { '#26314F' })
    }
    if ($Name -eq 'Manage') { Update-MachineList }
}

function Set-Busy {
    param([string]$Text, [string]$Sub = '')
    if ($Text) {
        $ui.BusyText.Text = $Text
        $ui.BusySub.Text = $Sub
        $ui.BusyVeil.Visibility = 'Visible'
    } else {
        $ui.BusyVeil.Visibility = 'Collapsed'
    }
}

# ---------------------------------------------------------------- create page
function Select-Guest {
    param([string]$Id)
    $app.Guest = $Id
    $kali = ($Id -eq 'kali')
    Set-Brush $ui.CardKali 'BorderBrush' $(if ($kali) { '#3E8BFF' } else { '#26314F' })
    Set-Brush $ui.CardKali 'Background' $(if ($kali) { '#16233F' } else { '#131B32' })
    Set-Brush $ui.DotKali 'Fill' $(if ($kali) { '#3E8BFF' } else { '#33405E' })
    Set-Brush $ui.CardDebian 'BorderBrush' $(if ($kali) { '#26314F' } else { '#3E8BFF' })
    Set-Brush $ui.CardDebian 'Background' $(if ($kali) { '#131B32' } else { '#16233F' })
    Set-Brush $ui.DotDebian 'Fill' $(if ($kali) { '#33405E' } else { '#3E8BFF' })
    Update-Plan
}

function Get-VmName {
    $typed = $ui.TxtVmName.Text.Trim()
    if ($typed) { return $typed }
    return ('AutoVM-{0}' -f $app.Guest)
}

function Update-Plan {
    if (-not $app.HostProfile) { return }
    try {
        $guest = Get-AutoVMGuestCatalog -Id $app.Guest
        $app.Plan = New-AutoVMPlan -HostProfile $app.HostProfile -Guest $guest -VMName (Get-VmName)
        $ui.PlanLine.Text = 'AutoVM will build {0} with {1} MB of memory, {2} processors and up to {3} GB of disk{4}.' -f
            $guest.name, $app.Plan.RamMB, $app.Plan.Cpus, $app.Plan.DiskGB,
            $(if ($app.Plan.TargetVolume) { " on drive $($app.Plan.TargetVolume):" } else { '' })
        $ui.PlanSub.Text = 'About {0} minutes. That is {1}% of this computer''s memory, so the rest stays yours.' -f
            $app.Plan.EstimatedMinutes, $app.Plan.HostRamShare
    } catch {
        $ui.PlanSub.Text = $_.Exception.Message
    }
    Update-CreateValidity
}

function Update-CreateValidity {
    $ok = $true
    $userName = $ui.TxtUser.Text
    $password = $ui.TxtPass.Password
    $confirm = $ui.TxtPass2.Password

    $nameCheck = Test-AutoVMUserName -UserName $userName
    if (-not $userName) {
        $ui.UserHint.Text = 'Letters, digits, hyphen and underscore.'
        Set-Brush $ui.UserHint 'Foreground' '#93A3C0'; $ok = $false
    } elseif (-not $nameCheck.IsValid) {
        $ui.UserHint.Text = $nameCheck.Reason
        Set-Brush $ui.UserHint 'Foreground' '#FF6B5E'; $ok = $false
    } else {
        $ui.UserHint.Text = if ($nameCheck.RequiresRename) { $nameCheck.Reason } else { "You will sign in as '$userName'." }
        Set-Brush $ui.UserHint 'Foreground' $(if ($nameCheck.RequiresRename) { '#F0B84E' } else { '#3FD69B' })
    }

    $passCheck = Test-AutoVMPassword -Password $password
    if (-not $password) {
        $ui.PassHint.Text = ''; $ui.StrengthBar.Width = 0; $ok = $false
    } elseif (-not $passCheck.IsValid) {
        $ui.PassHint.Text = $passCheck.Reason
        Set-Brush $ui.PassHint 'Foreground' '#FF6B5E'; $ok = $false
    } else {
        $ui.PassHint.Text = 'Strength: {0}.' -f $passCheck.Strength
        Set-Brush $ui.PassHint 'Foreground' $(if ($passCheck.IsWeak) { '#F0B84E' } else { '#3FD69B' })
        $ui.StrengthBar.Width = [math]::Min(1.0, $passCheck.Score / 5.0) * 260
        Set-Brush $ui.StrengthBar 'Background' $(
            if ($passCheck.Score -ge 4) { '#3FD69B' } elseif ($passCheck.Score -ge 3) { '#F0B84E' } else { '#FF6B5E' })
    }

    if (-not $confirm) { $ui.Pass2Hint.Text = ''; $ok = $false }
    elseif ($confirm -cne $password) { $ui.Pass2Hint.Text = 'The two passwords do not match.'; $ok = $false }
    else { $ui.Pass2Hint.Text = '' }

    if ($app.Verdict -and $app.Verdict.Status -eq 'Blocked') { $ok = $false }
    if (-not $app.HostProfile) { $ok = $false }

    $ui.BtnCreate.IsEnabled = $ok
}

function Start-DeviceScan {
    $ui.PlanLine.Text = 'Checking this device…'
    $ui.PlanSub.Text = ''
    $timer = New-Object Windows.Threading.DispatcherTimer
    $timer.Interval = [timespan]::FromMilliseconds(120)
    $timer.Add_Tick({ $timer.Stop(); Invoke-DeviceScan }.GetNewClosure())
    $timer.Start()
}

function Invoke-DeviceScan {
    try {
        $app.HostProfile = Get-AutoVMHostProfile
        $guest = Get-AutoVMGuestCatalog -Id $app.Guest
        $app.Plan = New-AutoVMPlan -HostProfile $app.HostProfile -Guest $guest -VMName (Get-VmName)
        $app.Gates = Test-AutoVMGate -HostProfile $app.HostProfile `
            -RequiredDiskGB $app.Plan.RequiredDiskGB -RequireElevation
        $app.Verdict = Get-AutoVMGateVerdict -Gates $app.Gates

        $rows = foreach ($gate in $app.Gates) {
            $colour = if ($gate.Passed) { '#3FD69B' }
            elseif ($gate.Severity -eq 'Halt') { '#FF6B5E' }
            elseif ($gate.Severity -eq 'Info') { '#93A3C0' } else { '#F0B84E' }
            [pscustomobject]@{
                Mark          = if ($gate.Passed) { [char]0x2713 } elseif ($gate.Severity -eq 'Halt') { [char]0x2715 } else { '!' }
                Colour        = $colour
                Title         = $gate.Title
                Detail        = $gate.Detail
                Advice        = $gate.Remediation
                AdviceVisible = if (-not $gate.Passed -and $gate.Remediation) { 'Visible' } else { 'Collapsed' }
            }
        }
        $ui.GateList.ItemsSource = @($rows)

        $ui.SideState.Text = '{0} · {1} GB' -f $app.HostProfile.ComputerModel, $app.HostProfile.TotalRAM_GB
        $ui.SideDetail.Text = '{0} logical cores' -f $app.HostProfile.LogicalCores

        if ($app.Verdict.Status -eq 'Blocked') {
            $blocker = @($app.Verdict.Halts)[0]
            $ui.PlanLine.Text = "This device cannot build a machine yet: $($blocker.Title.ToLower())."
            $ui.PlanSub.Text = $blocker.Remediation
            $ui.DeviceDetails.IsExpanded = $true
        } else {
            Update-Plan
            if ($app.Verdict.Status -eq 'NeedsDecision') {
                $ui.PlanSub.Text += '  Windows security features are using the virtualization extensions, so the machine will run in a slower mode.'
            }
        }
    } catch {
        $ui.PlanLine.Text = 'The device check could not finish.'
        $ui.PlanSub.Text = $_.Exception.Message
    }
    Update-CreateValidity
}

# ---------------------------------------------------------------- background
$engineWorker = {
    param($ModulePath, $Task, $Options, $Queue)

    Import-Module $ModulePath -Force
    Register-AutoVMProgressSink -Sink { param($record) $Queue.Enqueue($record) }

    try {
        $payload = switch ($Task) {
            'build' { Invoke-AutoVMBuild @Options }
            'snapshot' { New-AutoVMSnapshot @Options; 'done' }
            'restore' { Restore-AutoVMSnapshot @Options -Confirm:$false; 'done' }
            'dropSnapshot' { Remove-AutoVMSnapshot @Options -Confirm:$false; 'done' }
            'export' { Export-AutoVMMachine @Options }
            'deleteVm' { Remove-AutoVMMachine @Options -Confirm:$false; 'done' }
            default { throw "Unknown task '$Task'." }
        }
        $Queue.Enqueue([pscustomobject]@{ Level = 'Result'; Task = $Task; Message = ''; Payload = $payload; Percent = 100 })
    } catch {
        $Queue.Enqueue([pscustomobject]@{ Level = 'Result'; Task = $Task; Message = $_.Exception.Message; Payload = $null; Percent = 100 })
    }
}

function Start-EngineTask {
    param([string]$Task, [hashtable]$Options, [string]$Busy, [string]$BusySub = '')

    if ($app.Running) { Show-Message 'AutoVM is already busy with something.'; return }
    $app.Running = $true
    $app.Started = Get-Date

    $runspace = [runspacefactory]::CreateRunspace()
    $runspace.ApartmentState = 'MTA'
    $runspace.ThreadOptions = 'ReuseThread'
    $runspace.Open()

    $shell = [powershell]::Create()
    $shell.Runspace = $runspace
    [void]$shell.AddScript($engineWorker).AddArgument($ModulePath).AddArgument($Task).
        AddArgument($Options).AddArgument($app.Queue)

    $app.Runspace = $runspace
    $app.Shell = $shell
    [void]$shell.BeginInvoke()

    if ($Task -eq 'build') { Show-Page 'Building' } else { Set-Busy $Busy $BusySub }
}

function Stop-EngineTask {
    $app.Running = $false
    try { if ($app.Shell) { $app.Shell.Dispose() } } catch { }
    try { if ($app.Runspace) { $app.Runspace.Close(); $app.Runspace.Dispose() } } catch { }
    $app.Shell = $null
    $app.Runspace = $null
}

function Add-LogLine { param([string]$Text)
    $ui.LogBox.AppendText($Text + [Environment]::NewLine); $ui.LogScroller.ScrollToEnd() }

function Complete-Build {
    param($Report, [string]$Failure)

    Stop-EngineTask
    $app.Report = $Report

    if ($Report -and $Report.result -in @('SUCCESS', 'PARTIAL')) {
        $ui.DoneTitle.Text = if ($Report.result -eq 'SUCCESS') { 'Your machine is ready' } else { 'Built, with something to check' }
        $ui.DoneDeck.Text = 'Finished in {0}.' -f $Report.elapsed
        $ui.DoneNote.Text = $Report.handoverNote
        $ui.BtnGoManage.IsEnabled = $true
        $app.LoginName = $ui.TxtUser.Text
    } else {
        $message = if ($Failure) { $Failure } elseif ($Report) { $Report.failure } else { 'The build stopped before it finished.' }
        $ui.DoneTitle.Text = 'The build did not finish'
        $ui.DoneDeck.Text = 'Nothing was left running. The full log is on this device.'
        $ui.DoneNote.Text = $message + [Environment]::NewLine + [Environment]::NewLine +
        'What to try next:' + [Environment]::NewLine +
        '  - The message above names the step that stopped.' + [Environment]::NewLine +
        '  - Open the log for the detail.' + [Environment]::NewLine +
        '  - Fix what it describes and press Create VM Now! again. Work already done is not repeated.'
        $ui.BtnGoManage.IsEnabled = $false
    }
    Show-Page 'Ready'
}

# ---------------------------------------------------------------- manage page
function Get-StateColour {
    param([string]$State)
    switch -Regex ($State) {
        'running' { '#3FD69B' }
        'saved|paused' { '#F0B84E' }
        'poweroff|aborted' { '#FF6B5E' }
        default { '#6C7DA0' }
    }
}

function Update-MachineList {
    try {
        $app.Machines = @(Get-AutoVMMachine)
    } catch {
        $app.Machines = @()
    }

    $rows = foreach ($m in $app.Machines) {
        [pscustomobject]@{
            Name        = $m.Name
            Summary     = '{0} · {1} MB · {2} vCPU' -f $m.State, $m.RamMB, $m.Cpus
            StateColour = Get-StateColour $m.State
            Machine     = $m
        }
    }
    $selectedName = if ($app.Selected) { $app.Selected.Name } else { $null }
    $ui.MachineList.ItemsSource = @($rows)

    if (@($rows).Count -gt 0) {
        $index = 0
        for ($i = 0; $i -lt @($rows).Count; $i++) { if (@($rows)[$i].Name -eq $selectedName) { $index = $i } }
        $ui.MachineList.SelectedIndex = $index
    } else {
        $app.Selected = $null
        Clear-MachineDetail
    }

    if (@($app.Machines).Count -eq 0) {
        $ui.SideState.Text = 'No machine yet'
        $ui.SideDetail.Text = 'Create one from the first screen.'
    }
}

function Clear-MachineDetail {
    foreach ($k in 'OvState', 'OvLogin', 'OvGuest', 'OvHardware', 'OvDisk', 'OvIp') { $ui[$k].Text = '—' }
    $ui.SnapshotList.ItemsSource = @()
    $ui.ShareList.ItemsSource = @()
}

function Get-KnownLogin {
    if ($app.LoginName) { return $app.LoginName }
    try {
        $reportPath = Join-Path (Join-Path (Get-AutoVMRoot) 'manifests') 'build-report.json'
        if (Test-Path -LiteralPath $reportPath) {
            $report = Get-Content -LiteralPath $reportPath -Raw | ConvertFrom-Json
            if ($report.PSObject.Properties.Name -contains 'host') { }
            if ($report.PSObject.Properties.Name -contains 'handoverNote' -and $report.handoverNote -match 'Sign in as\s+(\S+)') {
                $app.LoginName = $Matches[1]
                return $app.LoginName
            }
        }
    } catch { }
    return 'the name you chose'
}

function Update-MachineDetail {
    $m = $app.Selected
    if (-not $m) { Clear-MachineDetail; return }

    $ui.OvState.Text = $m.State
    Set-Brush $ui.OvState 'Foreground' (Get-StateColour $m.State)
    $ui.OvLogin.Text = Get-KnownLogin
    $ui.OvGuest.Text = if ($m.GuestOS) { $m.GuestOS } else { 'not reported while shut down' }
    $ui.OvHardware.Text = '{0} MB memory · {1} processors · {2} MB video' -f $m.RamMB, $m.Cpus, $m.VramMB
    $ui.OvDisk.Text = if ($m.DiskUsedGB) { '{0} GB' -f $m.DiskUsedGB } else { 'unknown' }
    $ui.OvIp.Text = if ($m.IPAddress) { $m.IPAddress } else { '—' }

    $ui.SideState.Text = $m.Name
    $ui.SideDetail.Text = '{0} · {1} MB · {2} vCPU' -f $m.State, $m.RamMB, $m.Cpus

    $running = ($m.State -eq 'running')
    $off = ($m.State -in @('poweroff', 'aborted'))
    $ui.BtnStart.IsEnabled = -not $running
    $ui.BtnStartHeadless.IsEnabled = -not $running
    $ui.BtnShutdown.IsEnabled = $running
    $ui.BtnSaveState.IsEnabled = $running
    $ui.BtnPowerOff.IsEnabled = $running

    $ui.SetRam.Text = "$($m.RamMB)"
    $ui.SetCpus.Text = "$($m.Cpus)"
    $ui.SetVram.Text = "$($m.VramMB)"
    $ui.SetClipboard.SelectedIndex = switch ($m.Clipboard) {
        'bidirectional' { 0 } 'hosttoguest' { 1 } 'guesttohost' { 2 } default { 3 }
    }
    $ui.SettingsLocked.Visibility = if ($off) { 'Collapsed' } else { 'Visible' }
    $ui.BtnApplySettings.IsEnabled = $off
    foreach ($k in 'SetRam', 'SetCpus', 'SetVram', 'SetClipboard') { $ui[$k].IsEnabled = $off }

    if ($app.HostProfile) {
        $ceiling = [int]([math]::Floor([double]$app.HostProfile.TotalRAM_GB * 1024 * 0.5 / 4) * 4)
        $ui.RamHint.Text = "1024 – $ceiling on this device"
        $ui.CpuHint.Text = "1 – $($app.HostProfile.LogicalCores) on this device"
    }

    $ui.DeleteHint.Text = "Type $($m.Name) above to confirm."
    $ui.SettingsMsg.Text = ''

    try { $app.Snapshots = @(Get-AutoVMSnapshot -Name $m.Name) } catch { $app.Snapshots = @() }
    $ui.SnapshotList.ItemsSource = @($app.Snapshots)

    try { $app.Shares = @(Get-AutoVMSharedFolder -Name $m.Name) } catch { $app.Shares = @() }
    $ui.ShareList.ItemsSource = @($app.Shares | ForEach-Object { '{0}  →  {1}' -f $_.Name, $_.Path })
}

function Invoke-Power {
    param([string]$Action)
    $m = $app.Selected
    if (-not $m) { return }
    try {
        switch ($Action) {
            'gui' { Start-AutoVMMachine -Name $m.Name -Mode gui }
            'headless' { Start-AutoVMMachine -Name $m.Name -Mode headless }
            'shutdown' { Stop-AutoVMMachine -Name $m.Name -Mode shutdown -Confirm:$false }
            'save' { Stop-AutoVMMachine -Name $m.Name -Mode save -Confirm:$false }
            'poweroff' {
                if (-not (Confirm-Action "Force '$($m.Name)' off?`n`nAnything not yet written to its disk is lost. Use Shut down instead where you can.")) { return }
                Stop-AutoVMMachine -Name $m.Name -Mode poweroff -Confirm:$false
            }
        }
    } catch {
        Show-Message $_.Exception.Message 'AutoVM' 'Warning'
    }
    $refresh = New-Object Windows.Threading.DispatcherTimer
    $refresh.Interval = [timespan]::FromSeconds(3)
    $refresh.Add_Tick({ $refresh.Stop(); Update-MachineList }.GetNewClosure())
    $refresh.Start()
}

# ---------------------------------------------------------------- drain timer
$drain = New-Object Windows.Threading.DispatcherTimer
$drain.Interval = [timespan]::FromMilliseconds(220)
$drain.Add_Tick({
        $record = $null
        while ($app.Queue.TryDequeue([ref]$record)) {
            if ($record.Level -eq 'Result') {
                $task = $record.Task
                Stop-EngineTask
                Set-Busy ''
                switch ($task) {
                    'build' { Complete-Build -Report $record.Payload -Failure $record.Message }
                    'export' {
                        if ($record.Message) { Show-Message $record.Message 'Export' 'Warning' }
                        else { Show-Message "The machine was exported to:`n`n$($record.Payload)" }
                    }
                    default {
                        if ($record.Message) { Show-Message $record.Message 'AutoVM' 'Warning' }
                        Update-MachineList
                    }
                }
                continue
            }

            $stamp = if ($record.PSObject.Properties.Name -contains 'Timestamp') {
                ([datetime]$record.Timestamp).ToLocalTime().ToString('HH:mm:ss')
            } else { (Get-Date).ToString('HH:mm:ss') }

            if ($app.Page -eq 'Building') {
                Add-LogLine ('{0}  {1}' -f $stamp, $record.Message)
                if ($record.Level -in @('Step', 'Phase')) { $ui.BuildStatus.Text = $record.Message }
                if ($record.Percent -ge 0 -and $ui.ProgressFill.Parent) {
                    $ui.ProgressFill.Width = ($record.Percent / 100.0) * $ui.ProgressFill.Parent.ActualWidth
                }
                if ($record.Level -eq 'Error') { Set-Brush $ui.BuildStatus 'Foreground' '#FF6B5E' }
            } elseif ($record.Level -in @('Step', 'Phase')) {
                $ui.BusySub.Text = $record.Message
            }
        }

        if ($app.Running -and $app.Started -and $app.Page -eq 'Building') {
            $ui.BuildClock.Text = ((Get-Date) - $app.Started).ToString('hh\:mm\:ss')
        }
    })
$drain.Start()

# ---------------------------------------------------------------- events
$ui.NavCreate.Add_Click({ Show-Page 'Create' })
$ui.NavManage.Add_Click({ Show-Page 'Manage' })

$ui.CardKali.Add_MouseLeftButtonUp({ Select-Guest 'kali' })
$ui.CardDebian.Add_MouseLeftButtonUp({ Select-Guest 'debian' })

$ui.TxtUser.Add_TextChanged({ Update-CreateValidity })
$ui.TxtVmName.Add_TextChanged({ Update-CreateValidity })
$ui.TxtPass.Add_PasswordChanged({ Update-CreateValidity })
$ui.TxtPass2.Add_PasswordChanged({ Update-CreateValidity })

$ui.BtnCreate.Add_Click({
        $existing = @($app.Machines | Where-Object { $_.Name -eq (Get-VmName) })
        if ($existing) {
            Show-Message "A machine called '$(Get-VmName)' already exists. Choose a different machine name, or delete the existing one from My machines." 'AutoVM' 'Warning'
            return
        }

        $options = @{
            UserName = $ui.TxtUser.Text
            Password = $ui.TxtPass.SecurePassword
            GuestId  = $app.Guest
            VMName   = (Get-VmName)
        }
        if ($app.Verdict -and $app.Verdict.Status -eq 'NeedsDecision') {
            $options['AcceptDegradedVirtualization'] = $true
        }
        $app.LoginName = $ui.TxtUser.Text
        $ui.LogBox.Text = ''
        Set-Brush $ui.BuildStatus 'Foreground' '#E8EEF9'
        Start-EngineTask -Task 'build' -Options $options
    })

$ui.BtnCancelBuild.Add_Click({
        if (-not (Confirm-Action "Stop the build?`n`nThe work already finished is kept, and pressing Create VM Now! again continues from there.")) { return }
        try { $app.Shell.Stop() } catch { }
        Stop-EngineTask
        Show-Page 'Create'
    })

$ui.BtnCopyNote.Add_Click({ [System.Windows.Clipboard]::SetText($ui.DoneNote.Text); $ui.BtnCopyNote.Content = 'Copied' })
$ui.BtnOpenLogs.Add_Click({
        $logs = Join-Path (Get-AutoVMRoot) 'logs'
        if (Test-Path -LiteralPath $logs) { Start-Process explorer.exe $logs }
    })
$ui.BtnGoManage.Add_Click({ Show-Page 'Manage' })
$ui.BtnRefresh.Add_Click({ Update-MachineList })

$ui.MachineList.Add_SelectionChanged({
        $row = $ui.MachineList.SelectedItem
        $app.Selected = if ($row) { $row.Machine } else { $null }
        Update-MachineDetail
    })

$ui.BtnStart.Add_Click({ Invoke-Power 'gui' })
$ui.BtnStartHeadless.Add_Click({ Invoke-Power 'headless' })
$ui.BtnShutdown.Add_Click({ Invoke-Power 'shutdown' })
$ui.BtnSaveState.Add_Click({ Invoke-Power 'save' })
$ui.BtnPowerOff.Add_Click({ Invoke-Power 'poweroff' })
$ui.BtnVBoxGui.Add_Click({
        try {
            $dir = (Get-ItemProperty 'HKLM:\SOFTWARE\Oracle\VirtualBox' -ErrorAction Stop).InstallDir
            Start-Process (Join-Path $dir 'VirtualBox.exe')
        } catch { Show-Message 'VirtualBox Manager could not be found.' 'AutoVM' 'Warning' }
    })

$ui.BtnApplySettings.Add_Click({
        $m = $app.Selected
        if (-not $m -or -not $app.HostProfile) { return }
        $ram = 0; $cpus = 0; $vram = 0
        [void][int]::TryParse($ui.SetRam.Text, [ref]$ram)
        [void][int]::TryParse($ui.SetCpus.Text, [ref]$cpus)
        [void][int]::TryParse($ui.SetVram.Text, [ref]$vram)

        $change = Test-AutoVMSettingChange -HostProfile $app.HostProfile -Machine $m `
            -RamMB $ram -Cpus $cpus -VramMB $vram
        if (-not $change.IsValid) {
            $ui.SettingsMsg.Text = $change.Reason
            Set-Brush $ui.SettingsMsg 'Foreground' '#FF6B5E'
            return
        }
        $clipboard = @('bidirectional', 'hosttoguest', 'guesttohost', 'disabled')[[math]::Max(0, $ui.SetClipboard.SelectedIndex)]
        try {
            Set-AutoVMMachineSetting -Name $m.Name -Change $change -Clipboard $clipboard -Confirm:$false
            $ui.SettingsMsg.Text = 'Saved.' + $(if (@($change.Warnings).Count) { ' ' + (@($change.Warnings) -join ' ') } else { '' })
            Set-Brush $ui.SettingsMsg 'Foreground' $(if (@($change.Warnings).Count) { '#F0B84E' } else { '#3FD69B' })
            Update-MachineList
        } catch {
            $ui.SettingsMsg.Text = $_.Exception.Message
            Set-Brush $ui.SettingsMsg 'Foreground' '#FF6B5E'
        }
    })

$ui.BtnTakeSnapshot.Add_Click({
        $m = $app.Selected
        if (-not $m) { return }
        $name = $ui.TxtSnapshotName.Text
        $check = Test-AutoVMSnapshotName -Name $name
        if (-not $check.IsValid) { Show-Message $check.Reason 'Restore point' 'Warning'; return }
        $ui.TxtSnapshotName.Text = ''
        Start-EngineTask -Task 'snapshot' -Busy 'Taking a restore point…' `
            -BusySub 'This can take a minute on a large machine.' `
            -Options @{ Name = $m.Name; SnapshotName = $name; Description = "Taken from AutoVM on $(Get-Date -Format 'yyyy-MM-dd HH:mm')" }
    })

$ui.BtnRestoreSnapshot.Add_Click({
        $m = $app.Selected
        $snapshot = $ui.SnapshotList.SelectedItem
        if (-not $m -or -not $snapshot) { Show-Message 'Choose a restore point first.'; return }
        if (-not (Confirm-Action ("Restore '$($snapshot.Name)'?`n`nEverything saved inside the machine since that point is discarded. " +
                    'This cannot be undone.'))) { return }
        Start-EngineTask -Task 'restore' -Busy 'Restoring…' -BusySub $snapshot.Name `
            -Options @{ Name = $m.Name; SnapshotName = $snapshot.Name }
    })

$ui.BtnDeleteSnapshot.Add_Click({
        $m = $app.Selected
        $snapshot = $ui.SnapshotList.SelectedItem
        if (-not $m -or -not $snapshot) { Show-Message 'Choose a restore point first.'; return }
        if (-not (Confirm-Action "Delete the restore point '$($snapshot.Name)'?`n`nThe machine itself is not affected.")) { return }
        Start-EngineTask -Task 'dropSnapshot' -Busy 'Deleting the restore point…' `
            -BusySub 'Merging its disk changes back can take a few minutes.' `
            -Options @{ Name = $m.Name; SnapshotName = $snapshot.Name }
    })

$ui.BtnPickFolder.Add_Click({
        $dialog = New-Object System.Windows.Forms.FolderBrowserDialog
        $dialog.Description = 'Choose a folder to share with the machine'
        if ($dialog.ShowDialog() -eq 'OK') {
            $ui.TxtSharePath.Text = $dialog.SelectedPath
            if (-not $ui.TxtShareName.Text) {
                $leaf = Split-Path -Leaf $dialog.SelectedPath
                $ui.TxtShareName.Text = ($leaf -replace '[^A-Za-z0-9_-]', '')
            }
        }
    })

$ui.BtnAddShare.Add_Click({
        $m = $app.Selected
        if (-not $m) { return }
        try {
            Add-AutoVMSharedFolder -Name $m.Name -ShareName $ui.TxtShareName.Text `
                -Path $ui.TxtSharePath.Text -ReadOnly:$ui.ChkShareReadOnly.IsChecked
            $ui.ShareMsg.Text = "Shared. Inside the machine it appears under /media/sf_$($ui.TxtShareName.Text)."
            Set-Brush $ui.ShareMsg 'Foreground' '#3FD69B'
            $ui.TxtShareName.Text = ''; $ui.TxtSharePath.Text = ''
            Update-MachineDetail
        } catch {
            $ui.ShareMsg.Text = $_.Exception.Message
            Set-Brush $ui.ShareMsg 'Foreground' '#FF6B5E'
        }
    })

$ui.BtnRemoveShare.Add_Click({
        $m = $app.Selected
        $selected = $ui.ShareList.SelectedItem
        if (-not $m -or -not $selected) { Show-Message 'Choose a shared folder first.'; return }
        $shareName = ($selected -split '\s+→\s+')[0]
        try {
            Remove-AutoVMSharedFolder -Name $m.Name -ShareName $shareName -Confirm:$false
            Update-MachineDetail
        } catch { Show-Message $_.Exception.Message 'AutoVM' 'Warning' }
    })

$ui.BtnOpenVmFolder.Add_Click({
        $m = $app.Selected
        if ($m -and $m.Directory -and (Test-Path -LiteralPath $m.Directory)) {
            Start-Process explorer.exe $m.Directory
        } else { Show-Message "The machine's folder could not be found." 'AutoVM' 'Warning' }
    })

$ui.BtnExport.Add_Click({
        $m = $app.Selected
        if (-not $m) { return }
        if ($m.State -ne 'poweroff') { Show-Message 'Shut the machine down before exporting it.' 'AutoVM' 'Warning'; return }
        $dialog = New-Object System.Windows.Forms.SaveFileDialog
        $dialog.Filter = 'Virtual machine (*.ova)|*.ova'
        $dialog.FileName = "$($m.Name).ova"
        if ($dialog.ShowDialog() -ne 'OK') { return }
        Start-EngineTask -Task 'export' -Busy 'Exporting the machine…' `
            -BusySub 'This writes several gigabytes and can take a long time.' `
            -Options @{ Name = $m.Name; Path = $dialog.FileName }
    })

$ui.BtnDeleteVm.Add_Click({
        $m = $app.Selected
        if (-not $m) { return }
        if ($ui.TxtDeleteConfirm.Text -cne $m.Name) {
            Show-Message "Type the machine's name exactly - $($m.Name) - to confirm." 'Delete' 'Warning'
            return
        }
        if (-not (Confirm-Action ("Delete '$($m.Name)' and its disk?`n`nEverything inside the machine goes with it. " +
                    'This cannot be undone.'))) { return }
        $ui.TxtDeleteConfirm.Text = ''
        Start-EngineTask -Task 'deleteVm' -Busy 'Deleting the machine…' -BusySub $m.Name `
            -Options @{ Name = $m.Name; Confirmation = $m.Name }
    })

$window.Add_Closing({
        param($eventSender, $eventArgs)
        if ($app.Running) {
            $message = if ($app.Page -eq 'Building') {
                "The machine is still being built.`n`nClosing now stops the build. The work already done is kept, and starting AutoVM again continues from there. Close anyway?"
            } else {
                "AutoVM is still busy.`n`nClosing now interrupts it. Close anyway?"
            }
            if (-not (Confirm-Action $message)) { $eventArgs.Cancel = $true; return }
            try { $app.Shell.Stop() } catch { }
        }
        $drain.Stop()
    })

# ---------------------------------------------------------------- start
try { $ui.VersionLabel.Text = 'v' + (Get-Module AutoVM).Version.ToString() } catch { }

Select-Guest 'kali'
Start-DeviceScan

# If this device already has a machine, open on the management screen instead.
$existing = @()
try { $existing = @(Get-AutoVMMachine) } catch { }
if ($existing.Count -gt 0) {
    $app.Machines = $existing
    Show-Page 'Manage'
} else {
    Show-Page 'Create'
}

$window.ShowDialog() | Out-Null
