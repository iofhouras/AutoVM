<#
    AutoVM - desktop application.

    A six-step wizard over the AutoVM engine:

        Welcome -> This device -> Your account -> Review -> Building -> Ready

    The engine runs in its own runspace and reports progress through a
    concurrent queue that a dispatcher timer drains, so the window stays
    responsive across an install that can take an hour.
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

# WPF only runs on a single-threaded-apartment thread. PowerShell 7 uses STA by
# default on Windows, but a host that started this script differently would
# otherwise fail with an opaque error the moment the window is created.
if ([System.Threading.Thread]::CurrentThread.GetApartmentState() -ne 'STA') {
    $pwsh = (Get-Command pwsh.exe -ErrorAction SilentlyContinue).Source
    if ($pwsh) {
        Start-Process -FilePath $pwsh -ArgumentList @(
            '-STA', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden',
            '-File', "`"$PSCommandPath`"", '-ModulePath', "`"$ModulePath`"", '-NoElevate'
        ) -Verb RunAs
        return
    }
    throw 'AutoVM must run on a single-threaded-apartment host. Start it with: pwsh -STA -File AutoVM.ps1'
}

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Windows.Forms
Import-Module $ModulePath -Force

# Installing a hypervisor loads a kernel driver, so the whole run needs to be
# elevated. Relaunch once rather than failing three screens in.
function Test-Elevated {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    return ([Security.Principal.WindowsPrincipal]$id).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

if (-not (Test-Elevated) -and -not $NoElevate) {
    $shell = if (Get-Command pwsh.exe -ErrorAction SilentlyContinue) { 'pwsh.exe' } else { 'powershell.exe' }
    try {
        Start-Process -FilePath $shell -Verb RunAs -ArgumentList @(
            '-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden',
            '-File', "`"$PSCommandPath`"", '-ModulePath', "`"$ModulePath`""
        )
        return
    } catch {
        [System.Windows.Forms.MessageBox]::Show(
            "AutoVM needs administrator rights to install the virtualization software.`n`nClose this window, right-click AutoVM and choose 'Run as administrator'.",
            'AutoVM', 'OK', 'Warning') | Out-Null
        return
    }
}

# ---------------------------------------------------------------- window
$xamlPath = Join-Path $appRoot 'MainWindow.xaml'
[xml]$xaml = Get-Content -LiteralPath $xamlPath -Raw
$window = [Windows.Markup.XamlReader]::Load([System.Xml.XmlNodeReader]::new($xaml))

$ui = @{}
foreach ($name in @(
        'StepWelcome', 'StepDevice', 'StepAccount', 'StepReview', 'StepBuild', 'StepDone',
        'SidebarNote', 'FooterNote', 'BtnBack', 'BtnNext',
        'PageWelcome', 'PageDevice', 'PageAccount', 'PageReview', 'PageBuild', 'PageDone',
        'DeviceDeck', 'GateList', 'DeviceModel', 'DeviceRam', 'DeviceCpu', 'DeviceDisk', 'BtnRescan',
        'GuestKali', 'GuestDebian', 'GuestBlurb', 'TxtUser', 'UserHint', 'TxtVmName',
        'TxtPass', 'TxtPass2', 'StrengthBar', 'PassHint', 'Pass2Hint', 'CaseNote',
        'RvGuest', 'RvRam', 'RvCpu', 'RvDisk', 'RvUser', 'RvTime', 'WarningList',
        'AdvancedPanel', 'ChkTeardown', 'TeardownList', 'TxtDestroy',
        'BuildDeck', 'ProgressFill', 'BuildStatus', 'BuildClock', 'LogBox', 'LogScroller',
        'DoneTitle', 'DoneDeck', 'DoneNote', 'BtnOpenPanel', 'BtnOpenLogs', 'BtnCopyNote'
    )) {
    $ui[$name] = $window.FindName($name)
}

$state = [ordered]@{
    Page        = 0
    HostProfile = $null
    Gates       = @()
    Verdict     = $null
    Plan        = $null
    Guest       = $null
    Candidates  = @()
    Report      = $null
    Started     = $null
    Queue       = [System.Collections.Concurrent.ConcurrentQueue[psobject]]::new()
    Runspace    = $null
    Shell       = $null
    Handle      = $null
    Running     = $false
}

$pages = @('PageWelcome', 'PageDevice', 'PageAccount', 'PageReview', 'PageBuild', 'PageDone')
$steps = @('StepWelcome', 'StepDevice', 'StepAccount', 'StepReview', 'StepBuild', 'StepDone')

function Set-Brush { param($Element, [string]$Property, [string]$Hex)
    $Element.$Property = [Windows.Media.BrushConverter]::new().ConvertFromString($Hex) }

function Show-Page {
    param([int]$Index)
    $state.Page = $Index
    for ($i = 0; $i -lt $pages.Count; $i++) {
        $ui[$pages[$i]].Visibility = if ($i -eq $Index) { 'Visible' } else { 'Collapsed' }
        if ($i -lt $Index) { Set-Brush $ui[$steps[$i]] 'Foreground' '#3FD69B' }
        elseif ($i -eq $Index) { Set-Brush $ui[$steps[$i]] 'Foreground' '#FFFFFF' }
        else { Set-Brush $ui[$steps[$i]] 'Foreground' '#93A3C0' }
    }

    switch ($Index) {
        0 { $ui.BtnBack.IsEnabled = $false; $ui.BtnNext.Content = 'Get started'; $ui.BtnNext.IsEnabled = $true; $ui.FooterNote.Text = '' }
        1 { $ui.BtnBack.IsEnabled = $true; $ui.BtnNext.Content = 'Continue'; Start-DeviceScan }
        2 { $ui.BtnBack.IsEnabled = $true; $ui.BtnNext.Content = 'Continue'; Update-AccountValidity }
        3 { $ui.BtnBack.IsEnabled = $true; $ui.BtnNext.Content = 'Build my machine'; $ui.BtnNext.IsEnabled = $true; Update-ReviewPage }
        4 { $ui.BtnBack.IsEnabled = $false; $ui.BtnNext.Content = 'Building...'; $ui.BtnNext.IsEnabled = $false }
        5 { $ui.BtnBack.IsEnabled = $false; $ui.BtnNext.Content = 'Finish'; $ui.BtnNext.IsEnabled = $true; $ui.FooterNote.Text = '' }
    }
}

# ---------------------------------------------------------------- device scan
function Start-DeviceScan {
    $ui.DeviceDeck.Text = 'Checking what this computer can do...'
    $ui.GateList.ItemsSource = $null
    $ui.BtnNext.IsEnabled = $false
    $ui.BtnRescan.IsEnabled = $false

    # Let the window paint the "checking" state before the scan blocks on CIM.
    $timer = New-Object Windows.Threading.DispatcherTimer
    $timer.Interval = [timespan]::FromMilliseconds(120)
    $timer.Add_Tick({
            $timer.Stop()
            Invoke-DeviceScan
        }.GetNewClosure())
    $timer.Start()
}

function Invoke-DeviceScan {
    try {
        $state.HostProfile = Get-AutoVMHostProfile
        $state.Guest = Get-AutoVMGuestCatalog -Id (Get-SelectedGuestId)
        $state.Plan = New-AutoVMPlan -HostProfile $state.HostProfile -Guest $state.Guest -VMName (Get-VmName)
        $state.Gates = Test-AutoVMGate -HostProfile $state.HostProfile -RequiredDiskGB $state.Plan.RequiredDiskGB -RequireElevation
        $state.Verdict = Get-AutoVMGateVerdict -Gates $state.Gates

        $rows = foreach ($gate in $state.Gates) {
            $colour = if ($gate.Passed) { '#3FD69B' }
            elseif ($gate.Severity -eq 'Halt') { '#FF6B5E' }
            elseif ($gate.Severity -eq 'Info') { '#93A3C0' }
            else { '#F0B84E' }
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

        $p = $state.HostProfile
        $ui.DeviceModel.Text = if ($p.ComputerModel) { $p.ComputerModel } else { 'this computer' }
        $ui.DeviceRam.Text = '{0} GB installed' -f $p.TotalRAM_GB
        $ui.DeviceCpu.Text = '{0} ({1} logical cores)' -f $p.CPUName, $p.LogicalCores
        $best = @($p.Volumes | Sort-Object FreeGB -Descending | Select-Object -First 1)
        $ui.DeviceDisk.Text = if ($best) { '{0} GB free on {1}:' -f $best[0].FreeGB, $best[0].Letter } else { 'no fixed volume found' }

        $ui.DeviceDeck.Text = $state.Verdict.Summary
        $ui.BtnNext.IsEnabled = ($state.Verdict.Status -ne 'Blocked')
        $ui.FooterNote.Text = if ($state.Verdict.Status -eq 'Blocked') {
            'Fix the item marked in red, then choose Check again.'
        } elseif ($state.Verdict.Status -eq 'NeedsDecision') {
            'You can continue - the trade-off above is recorded in the build report.'
        } else { '' }
    } catch {
        $ui.DeviceDeck.Text = "The device check could not finish: $($_.Exception.Message)"
        $ui.BtnNext.IsEnabled = $false
    } finally {
        $ui.BtnRescan.IsEnabled = $true
    }
}

# ---------------------------------------------------------------- account page
function Get-SelectedGuestId { if ($ui.GuestDebian.IsChecked) { 'debian' } else { 'kali' } }

function Get-VmName {
    $typed = $ui.TxtVmName.Text.Trim()
    if ($typed) { return $typed }
    return ('AutoVM-{0}' -f (Get-SelectedGuestId))
}

function Update-GuestBlurb {
    $guest = Get-AutoVMGuestCatalog -Id (Get-SelectedGuestId)
    $ui.GuestBlurb.Text = '{0}  -  about {1} minutes to install.' -f $guest.description, $guest.estimatedMinutes
}

function Update-AccountValidity {
    $userName = $ui.TxtUser.Text
    $password = $ui.TxtPass.Password
    $confirm = $ui.TxtPass2.Password
    $ok = $true

    $nameCheck = Test-AutoVMUserName -UserName $userName
    if (-not $userName) {
        $ui.UserHint.Text = 'Letters, digits, hyphen and underscore.'
        Set-Brush $ui.UserHint 'Foreground' '#93A3C0'
        $ok = $false
    } elseif (-not $nameCheck.IsValid) {
        $ui.UserHint.Text = $nameCheck.Reason
        Set-Brush $ui.UserHint 'Foreground' '#FF6B5E'
        $ok = $false
    } else {
        $ui.UserHint.Text = if ($nameCheck.RequiresRename) { $nameCheck.Reason } else { "You will sign in as '$userName'." }
        Set-Brush $ui.UserHint 'Foreground' $(if ($nameCheck.RequiresRename) { '#F0B84E' } else { '#3FD69B' })
    }

    $passCheck = Test-AutoVMPassword -Password $password
    if (-not $password) {
        $ui.PassHint.Text = ''
        $ui.StrengthBar.Width = 0
        $ok = $false
    } elseif (-not $passCheck.IsValid) {
        $ui.PassHint.Text = $passCheck.Reason
        Set-Brush $ui.PassHint 'Foreground' '#FF6B5E'
        $ok = $false
    } else {
        $ui.PassHint.Text = 'Strength: {0}.{1}' -f $passCheck.Strength,
            $(if ($passCheck.IsWeak) { ' Acceptable here because the machine has no way in from the network.' } else { '' })
        Set-Brush $ui.PassHint 'Foreground' $(if ($passCheck.IsWeak) { '#F0B84E' } else { '#3FD69B' })
        $ui.StrengthBar.Width = [math]::Min(1.0, $passCheck.Score / 5.0) * 240
        Set-Brush $ui.StrengthBar 'Background' $(
            if ($passCheck.Score -ge 4) { '#3FD69B' } elseif ($passCheck.Score -ge 3) { '#F0B84E' } else { '#FF6B5E' })
    }

    if ($confirm -and $confirm -cne $password) {
        $ui.Pass2Hint.Text = 'The two passwords do not match.'
        $ok = $false
    } elseif (-not $confirm) {
        $ui.Pass2Hint.Text = ''
        $ok = $false
    } else {
        $ui.Pass2Hint.Text = ''
    }

    $ui.BtnNext.IsEnabled = $ok
    $ui.FooterNote.Text = if ($ok) { '' } else { 'Fill in a login name and a matching password to continue.' }
    return $ok
}

# ---------------------------------------------------------------- review page
function Update-ReviewPage {
    $state.Guest = Get-AutoVMGuestCatalog -Id (Get-SelectedGuestId)
    $state.Plan = New-AutoVMPlan -HostProfile $state.HostProfile -Guest $state.Guest -VMName (Get-VmName)
    $plan = $state.Plan

    $ui.RvGuest.Text = '{0} ({1} package set)' -f $plan.GuestName, $plan.ProfileName
    $ui.RvRam.Text = '{0} MB   -   {1}% of this device' -f $plan.RamMB, $plan.HostRamShare
    $ui.RvCpu.Text = '{0} of {1} logical cores' -f $plan.Cpus, $state.HostProfile.LogicalCores
    $ui.RvDisk.Text = if ($plan.TargetVolume) {
        'up to {0} GB on drive {1}:  (grows as needed)' -f $plan.DiskGB, $plan.TargetVolume
    } else { 'no volume with enough space' }
    $ui.RvUser.Text = $ui.TxtUser.Text
    $ui.RvTime.Text = 'about {0} minutes' -f $plan.EstimatedMinutes

    $warnings = [System.Collections.Generic.List[string]]::new()
    foreach ($warning in $plan.Warnings) { $warnings.Add($warning) }
    foreach ($decision in $state.Verdict.Decisions) { $warnings.Add($decision.Remediation) }
    $ui.WarningList.ItemsSource = @($warnings)

    try {
        $state.Candidates = @(Get-AutoVMTeardownCandidate -IncludeLooseImages)
    } catch {
        $state.Candidates = @()
    }
    $ui.TeardownList.ItemsSource = @($state.Candidates | ForEach-Object {
            '{0}  {1}{2}' -f $_.Kind, $_.Name, $(if ($_.Protected) { '   [protected - will be kept]' } else { '' })
        })
    $ui.AdvancedPanel.Visibility = if ($state.Candidates.Count) { 'Visible' } else { 'Collapsed' }
    $ui.FooterNote.Text = 'Nothing has been changed on this device yet.'
}

# ---------------------------------------------------------------- build
$buildWorker = {
    param($ModulePath, $Options, $Queue)

    Import-Module $ModulePath -Force
    Register-AutoVMProgressSink -Sink { param($record) $Queue.Enqueue($record) }

    try {
        $report = Invoke-AutoVMBuild @Options
        $Queue.Enqueue([pscustomobject]@{ Level = 'Result'; Message = ''; Report = $report; Percent = 100 })
    } catch {
        $Queue.Enqueue([pscustomobject]@{ Level = 'Result'; Message = $_.Exception.Message; Report = $null; Percent = 100 })
    }
}

function Start-Build {
    $options = @{
        UserName = $ui.TxtUser.Text
        Password = $ui.TxtPass.SecurePassword
        GuestId  = (Get-SelectedGuestId)
        VMName   = (Get-VmName)
    }
    if ($state.Verdict.Status -eq 'NeedsDecision') { $options['AcceptDegradedVirtualization'] = $true }
    if ($ui.ChkTeardown.IsChecked -and $ui.TxtDestroy.Text -ceq 'DESTROY') {
        $options['RemoveExistingVMs'] = $true
        $options['TeardownConfirmation'] = 'DESTROY'
    }

    $state.Started = Get-Date
    $state.Running = $true
    $ui.LogBox.Text = ''
    Show-Page 4

    $runspace = [runspacefactory]::CreateRunspace()
    $runspace.ApartmentState = 'MTA'
    $runspace.ThreadOptions = 'ReuseThread'
    $runspace.Open()

    $shell = [powershell]::Create()
    $shell.Runspace = $runspace
    [void]$shell.AddScript($buildWorker).AddArgument($ModulePath).AddArgument($options).AddArgument($state.Queue)

    $state.Runspace = $runspace
    $state.Shell = $shell
    $state.Handle = $shell.BeginInvoke()
}

function Add-LogLine {
    param([string]$Text)
    $ui.LogBox.AppendText($Text + [Environment]::NewLine)
    $ui.LogScroller.ScrollToEnd()
}

function Complete-Build {
    param($Report, [string]$Failure)

    $state.Running = $false
    try {
        if ($state.Shell) { $state.Shell.Dispose() }
        if ($state.Runspace) { $state.Runspace.Close(); $state.Runspace.Dispose() }
    } catch { }

    $state.Report = $Report

    if ($Report -and $Report.result -in @('SUCCESS', 'PARTIAL')) {
        $ui.DoneTitle.Text = if ($Report.result -eq 'SUCCESS') { 'Your machine is ready' } else { 'Built, with something to check' }
        $ui.DoneDeck.Text = 'Finished in {0}.' -f $Report.elapsed
        $ui.DoneNote.Text = $Report.handoverNote
        $ui.BtnOpenPanel.IsEnabled = [bool]$Report.shortcutPath
    } else {
        $message = if ($Failure) { $Failure } elseif ($Report) { $Report.failure } else { 'The build stopped before it finished.' }
        $ui.DoneTitle.Text = 'The build did not finish'
        $ui.DoneDeck.Text = 'Nothing was left running. The full log is on this device.'
        $ui.DoneNote.Text = $message + [Environment]::NewLine + [Environment]::NewLine +
        'What to try next:' + [Environment]::NewLine +
        '  - Read the message above; it names the step that stopped.' + [Environment]::NewLine +
        '  - Open the build log for the detail.' + [Environment]::NewLine +
        '  - Fix what it describes and start AutoVM again. Work already done is not repeated.'
        $ui.BtnOpenPanel.IsEnabled = $false
    }
    Show-Page 5
}

$drain = New-Object Windows.Threading.DispatcherTimer
$drain.Interval = [timespan]::FromMilliseconds(220)
$drain.Add_Tick({
        $record = $null
        while ($state.Queue.TryDequeue([ref]$record)) {
            if ($record.Level -eq 'Result') {
                Complete-Build -Report $record.Report -Failure $record.Message
                continue
            }

            $stamp = if ($record.PSObject.Properties.Name -contains 'Timestamp') {
                ([datetime]$record.Timestamp).ToLocalTime().ToString('HH:mm:ss')
            } else { (Get-Date).ToString('HH:mm:ss') }

            Add-LogLine ('{0}  {1}' -f $stamp, $record.Message)

            if ($record.Level -in @('Step', 'Phase')) { $ui.BuildStatus.Text = $record.Message }
            if ($record.Percent -ge 0) {
                $ui.ProgressFill.Width = ($record.Percent / 100.0) * ($ui.ProgressFill.Parent.ActualWidth)
            }
            if ($record.Level -eq 'Error') { Set-Brush $ui.BuildStatus 'Foreground' '#FF6B5E' }
        }

        if ($state.Running -and $state.Started) {
            $ui.BuildClock.Text = ((Get-Date) - $state.Started).ToString('hh\:mm\:ss')
        }
    })
$drain.Start()

# ---------------------------------------------------------------- events
$ui.BtnNext.Add_Click({
        switch ($state.Page) {
            0 { Show-Page 1 }
            1 { Show-Page 2 }
            2 { if (Update-AccountValidity) { Show-Page 3 } }
            3 {
                if ($ui.ChkTeardown.IsChecked -and $ui.TxtDestroy.Text -cne 'DESTROY') {
                    [System.Windows.MessageBox]::Show(
                        "To remove the machines you selected, type DESTROY in capitals in the confirmation box.`n`nLeave the box empty to build without removing anything.",
                        'AutoVM', 'OK', 'Warning') | Out-Null
                    return
                }
                Start-Build
            }
            5 { $window.Close() }
        }
    })

$ui.BtnBack.Add_Click({ if ($state.Page -gt 0) { Show-Page ($state.Page - 1) } })
$ui.BtnRescan.Add_Click({ Start-DeviceScan })

$ui.TxtUser.Add_TextChanged({ if ($state.Page -eq 2) { [void](Update-AccountValidity) } })
$ui.TxtPass.Add_PasswordChanged({ if ($state.Page -eq 2) { [void](Update-AccountValidity) } })
$ui.TxtPass2.Add_PasswordChanged({ if ($state.Page -eq 2) { [void](Update-AccountValidity) } })
$ui.GuestKali.Add_Checked({ Update-GuestBlurb })
$ui.GuestDebian.Add_Checked({ Update-GuestBlurb })

$ui.BtnOpenPanel.Add_Click({
        if ($state.Report -and $state.Report.shortcutPath) {
            Start-Process -FilePath $state.Report.shortcutPath
        }
    })
$ui.BtnOpenLogs.Add_Click({
        $logs = Join-Path (Get-AutoVMRoot) 'logs'
        if (Test-Path -LiteralPath $logs) { Start-Process explorer.exe $logs }
    })
$ui.BtnCopyNote.Add_Click({
        [System.Windows.Clipboard]::SetText($ui.DoneNote.Text)
        $ui.BtnCopyNote.Content = 'Copied'
    })

$window.Add_Closing({
        param($eventSender, $eventArgs)
        if ($state.Running) {
            $answer = [System.Windows.MessageBox]::Show(
                "The virtual machine is still being built.`n`nClosing now stops the build. The work already done is kept, and starting AutoVM again will carry on from there. Close anyway?",
                'AutoVM', 'YesNo', 'Warning')
            if ($answer -ne 'Yes') { $eventArgs.Cancel = $true; return }
            try { $state.Shell.Stop() } catch { }
        }
        $drain.Stop()
    })

Update-GuestBlurb
Show-Page 0
$window.ShowDialog() | Out-Null
