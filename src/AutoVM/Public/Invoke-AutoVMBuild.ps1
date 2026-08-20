function Invoke-AutoVMBuild {
    <#
        .SYNOPSIS
        Builds a virtual machine on this device, start to finish.

        .DESCRIPTION
        Runs the seven build phases in order, recording each outcome so an
        interrupted run resumes rather than restarts:

            P1  profile the device and evaluate the pre-flight gates
            P2  remove existing machines (only when asked, only with consent)
            P3  install VirtualBox and the archive tool
            P4  resolve, download and verify the guest image
            P5  create the machine and drive the unattended install
            P6  prove the account works and take a restore point
            P7  write the control panel and the desktop shortcut

        A phase that cannot prove its exit condition fails; it does not guess.

        .PARAMETER UserName
        The login the user wants inside the guest. Capitals are handled: the
        account is created lowercase, because the installer accepts nothing
        else, then renamed once it exists.

        .PARAMETER Password
        The guest account password, as a SecureString. It is converted to text
        only where the installer answer file needs it, and that file is
        overwritten and deleted afterwards.

        .PARAMETER RemoveExistingVMs
        Opt in to removing virtual machines already on the device. Requires
        -TeardownConfirmation to be exactly 'DESTROY'.

        .PARAMETER WhatIfPlanOnly
        Profile the device, plan the machine and evaluate the gates, then stop
        and return the plan without changing anything.

        .EXAMPLE
        $pw = Read-Host 'Password' -AsSecureString
        Invoke-AutoVMBuild -UserName 'Kali' -Password $pw

        .EXAMPLE
        Invoke-AutoVMBuild -UserName 'dev' -Password $pw -GuestId debian -Headless

        .OUTPUTS
        A build report: result, plan, gate outcomes, acceptance checks,
        artifacts and the handover note.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([psobject])]
    param(
        [Parameter(Mandatory)][string]$UserName,
        [Parameter(Mandatory)][securestring]$Password,
        [string]$GuestId = 'kali',
        [string]$VMName,
        [string]$FullName,
        [ValidateSet('Auto', 'Light', 'Full')][string]$Profile = 'Auto',
        [string]$PreferredVolume,
        [switch]$Headless,
        [switch]$RemoveExistingVMs,
        [string]$TeardownConfirmation,
        [switch]$AcceptDegradedVirtualization,
        [switch]$WhatIfPlanOnly,
        [int]$InstallTimeoutMinutes = 90,
        [string]$Root = (Get-AutoVMRoot)
    )

    $started = Get-Date
    $root = Initialize-AutoVMRoot -Root $Root
    $state = Get-AutoVMState -Root $root
    Initialize-AutoVMLog -Root $root -BuildId $state.buildId | Out-Null

    $plainForRedaction = ConvertFrom-AutoVMSecureString -Secure $Password
    Register-AutoVMSecret -Value $plainForRedaction
    $plainForRedaction = $null

    $guest = Get-AutoVMGuestCatalog -Id $GuestId
    if (-not $VMName) { $VMName = 'AutoVM-{0}' -f $guest.id }

    $created = [System.Collections.Generic.List[string]]::new()
    $destroyed = [System.Collections.Generic.List[string]]::new()
    $preseedPath = $null

    $report = [pscustomobject]@{
        buildId      = $state.buildId
        result       = 'FAILED'
        startedAt    = $started.ToUniversalTime().ToString('o')
        finishedAt   = $null
        elapsed      = ''
        guest        = $guest.name
        vmName       = $VMName
        host         = $null
        plan         = $null
        gates        = @()
        acceptance   = [ordered]@{}
        image        = [pscustomobject]@{ file = ''; sha256 = ''; verified = $false }
        destroyed    = @()
        created      = @()
        shortcutPath = ''
        handoverNote = ''
        warnings     = [System.Collections.Generic.List[string]]::new()
        failure      = ''
    }

    try {
        # ---------------------------------------------------------------- P1
        Set-AutoVMPhase 'P1'
        $phaseStart = Get-Date
        Write-AutoVMLog -Level Phase -Message 'Phase 1 of 7 - looking at this device' -Percent 2

        $manifests = Join-Path $root 'manifests'
        $hostProfile = Get-AutoVMHostProfile -Path (Join-Path $manifests 'host-profile.json')
        $report.host = $hostProfile

        $credentialPlan = New-AutoVMCredentialPlan -UserName $UserName -Password $Password -FullName $FullName
        if (-not $credentialPlan.IsValid) {
            throw ("The login or password cannot be used: {0}" -f ($credentialPlan.Notes -join ' '))
        }
        foreach ($note in $credentialPlan.Notes) { $report.warnings.Add($note) }

        $plan = New-AutoVMPlan -HostProfile $hostProfile -Guest $guest -VMName $VMName `
            -Profile $Profile -PreferredVolume $PreferredVolume
        $report.plan = $plan
        foreach ($warning in $plan.Warnings) { $report.warnings.Add($warning) }
        Write-AutoVMLog -Level Info -Message (Format-AutoVMPlanSummary -Plan $plan)

        # Planning is read-only, so it does not need administrator rights; building does.
        $gates = Test-AutoVMGate -HostProfile $hostProfile -RequiredDiskGB $plan.RequiredDiskGB `
            -RequireElevation:(-not $WhatIfPlanOnly)
        $report.gates = $gates
        $verdict = Get-AutoVMGateVerdict -Gates $gates

        foreach ($gate in $gates) {
            $level = if ($gate.Passed) { 'Info' } else { if ($gate.Severity -eq 'Info') { 'Info' } else { 'Gate' } }
            Write-AutoVMLog -Level $level -Message ('{0} {1}: {2}' -f $gate.Id,
                $(if ($gate.Passed) { 'ok' } else { $gate.Severity.ToLowerInvariant() }), $gate.Detail)
        }

        if ($verdict.Status -eq 'Blocked') {
            $remedies = ($verdict.Halts | ForEach-Object { '{0} - {1}' -f $_.Title, $_.Remediation }) -join [Environment]::NewLine
            throw ("This device is not ready yet." + [Environment]::NewLine + $remedies)
        }
        if ($verdict.Status -eq 'NeedsDecision' -and -not $AcceptDegradedVirtualization) {
            foreach ($decision in $verdict.Decisions) {
                $report.warnings.Add(('{0}: {1}' -f $decision.Title, $decision.Remediation))
            }
            Write-AutoVMLog -Level Warn -Message 'Continuing with a trade-off that was not explicitly accepted; it is recorded in the report.'
        }
        if ($AcceptDegradedVirtualization) {
            foreach ($decision in $verdict.Decisions) {
                Add-AutoVMDecision -State $state -Gate $decision.Id -Question $decision.Title -Answer 'accepted' -Root $root
            }
        }

        Complete-AutoVMPhase -State $state -Id 'P1' -Result 'PASS' -Elapsed ((Get-Date) - $phaseStart) `
            -Created @('manifests/host-profile.json') -Root $root | Out-Null

        if ($WhatIfPlanOnly) {
            $report.result = 'PLANNED'
            $report.finishedAt = (Get-Date).ToUniversalTime().ToString('o')
            $report.warnings = @($report.warnings)
            return $report
        }

        # ---------------------------------------------------------------- P2
        Set-AutoVMPhase 'P2'
        $phaseStart = Get-Date
        if ($RemoveExistingVMs) {
            Write-AutoVMLog -Level Phase -Message 'Phase 2 of 7 - removing the machines you selected' -Percent 12
            $candidates = Get-AutoVMTeardownCandidate -IncludeLooseImages
            if ($candidates.Count -eq 0) {
                Write-AutoVMLog -Level Info -Message 'Nothing to remove.'
                Complete-AutoVMPhase -State $state -Id 'P2' -Result 'SKIPPED' -Elapsed ((Get-Date) - $phaseStart) -Root $root | Out-Null
            } else {
                if ($PSCmdlet.ShouldProcess("$($candidates.Count) item(s)", 'delete')) {
                    $removed = Invoke-AutoVMTeardown -Candidates $candidates -Confirmation $TeardownConfirmation -Confirm:$false
                    foreach ($item in $removed) { $destroyed.Add($item) }
                }
                Complete-AutoVMPhase -State $state -Id 'P2' -Result 'PASS' -Destroyed $destroyed.ToArray() `
                    -Elapsed ((Get-Date) - $phaseStart) -Root $root | Out-Null
            }
        } else {
            Write-AutoVMLog -Level Info -Message 'Phase 2 of 7 - skipped: existing virtual machines are left alone.'
            Complete-AutoVMPhase -State $state -Id 'P2' -Result 'SKIPPED' -Elapsed ([timespan]::Zero) -Root $root | Out-Null
        }

        # ---------------------------------------------------------------- P3
        Set-AutoVMPhase 'P3'
        $phaseStart = Get-Date
        Write-AutoVMLog -Level Phase -Message 'Phase 3 of 7 - installing VirtualBox' -Percent 18

        $version = Get-AutoVMVirtualBoxVersion
        if ($version) {
            Write-AutoVMLog -Level Info -Message "VirtualBox $version is already installed."
        } else {
            $version = Install-AutoVMVirtualBox
            $created.Add('Oracle VirtualBox')
        }
        $report.acceptance['hypervisorReady'] = [bool]($version -match '^\d+')
        Complete-AutoVMPhase -State $state -Id 'P3' -Result 'PASS' -Elapsed ((Get-Date) - $phaseStart) `
            -Created @("VirtualBox $version") -Root $root | Out-Null

        # ---------------------------------------------------------------- P4
        Set-AutoVMPhase 'P4'
        $phaseStart = Get-Date
        Write-AutoVMLog -Level Phase -Message "Phase 4 of 7 - downloading $($guest.name)" -Percent 30

        $image = Resolve-AutoVMImage -Guest $guest
        $download = Get-AutoVMImage -Image $image -CacheDirectory (Join-Path $root 'cache')
        $report.image = [pscustomobject]@{ file = $image.FileName; sha256 = $download.Sha256; verified = $true }
        $state.artifacts.isoPath = $download.Path
        $state.artifacts.isoSha256 = $download.Sha256
        Save-AutoVMState -State $state -Root $root

        Complete-AutoVMPhase -State $state -Id 'P4' -Result 'PASS' -Elapsed ((Get-Date) - $phaseStart) `
            -Created @($download.Path) -Root $root | Out-Null

        # ---------------------------------------------------------------- P5
        Set-AutoVMPhase 'P5'
        $phaseStart = Get-Date
        Write-AutoVMLog -Level Phase -Message 'Phase 5 of 7 - building the virtual machine' -Percent 44

        if ((Get-AutoVMVmName) -contains $VMName) {
            throw ("A virtual machine called '$VMName' already exists on this device. " +
                'Choose a different name, or remove the existing machine first.')
        }

        $machine = New-AutoVMVirtualMachine -Plan $plan -IsoPath $download.Path -Confirm:$false
        $created.Add($machine.DiskPath)
        $state.artifacts.vmDir = $machine.Directory
        $state.artifacts.vmName = $VMName
        Save-AutoVMState -State $state -Root $root

        $preseedText = New-AutoVMPreseed -Plan $plan -Guest $guest -UserName $UserName -Password $Password `
            -FullName $credentialPlan.FullName -HostName $guest.id `
            -AllowWeakPassword:$credentialPlan.AllowWeak
        $runDir = Join-Path (Join-Path $root 'run') $state.buildId
        $preseedPath = Write-AutoVMPreseed -Content $preseedText -RunDirectory $runDir

        Start-AutoVMUnattendedInstall -Plan $plan -IsoPath $download.Path -PreseedPath $preseedPath `
            -CredentialPlan $credentialPlan -HostName $guest.id -Headless:$Headless

        $install = Wait-AutoVMInstall -VMName $VMName -TimeoutMinutes $InstallTimeoutMinutes `
            -ScreenshotDirectory (Join-Path $root 'logs')

        if (-not $install.Completed) {
            $detail = $install.Reason
            if ($install.PSObject.Properties.Name -contains 'Screenshot' -and $install.Screenshot) {
                $detail += " A picture of what the machine is showing was saved to $($install.Screenshot)."
            }
            throw "AUTOVM-P5: $detail"
        }

        Write-AutoVMLog -Level Success -Message "The guest is up and reports $($install.Product)."
        Complete-AutoVMPhase -State $state -Id 'P5' -Result 'PASS' -Elapsed ((Get-Date) - $phaseStart) `
            -Created @($VMName) -Root $root | Out-Null

        # ---------------------------------------------------------------- P6
        Set-AutoVMPhase 'P6'
        $phaseStart = Get-Date
        Write-AutoVMLog -Level Phase -Message 'Phase 6 of 7 - checking the machine and taking a restore point' -Percent 90

        Dismount-AutoVMInstaller -VMName $VMName

        $login = Test-AutoVMGuestLogin -VMName $VMName -UserName $UserName -Password $Password
        if (-not $login.Success -and $credentialPlan.RequiresRename) {
            Repair-AutoVMGuestAccount -VMName $VMName -InstallerName $credentialPlan.InstallerName `
                -TargetName $UserName -Password $Password
            Start-Sleep -Seconds 5
            $login = Test-AutoVMGuestLogin -VMName $VMName -UserName $UserName -Password $Password
        }
        if (-not $login.Success) {
            throw ("AUTOVM-P6: The account '$UserName' could not be verified inside the guest. " +
                "The machine was built, but the sign-in has not been proved. Details: $($login.Error)")
        }
        Write-AutoVMLog -Level Success -Message "Signed in to the guest as $UserName."
        $report.acceptance['accountVerified'] = $true

        $osProduct = Get-AutoVMGuestProperty -VMName $VMName -Name '/VirtualBox/GuestInfo/OS/Product'
        $report.acceptance['guestToolsLive'] = [bool]$osProduct

        New-AutoVMBaselineSnapshot -VMName $VMName
        $report.acceptance['restorePoint'] = (Test-AutoVMSnapshot -VMName $VMName)

        Complete-AutoVMPhase -State $state -Id 'P6' -Result 'PASS' -Elapsed ((Get-Date) - $phaseStart) `
            -Created @('snapshot clean-baseline') -Root $root | Out-Null

        # ---------------------------------------------------------------- P7
        Set-AutoVMPhase 'P7'
        $phaseStart = Get-Date
        Write-AutoVMLog -Level Phase -Message 'Phase 7 of 7 - putting the control panel on your desktop' -Percent 96

        $panel = New-AutoVMControlCenter -Root $root -VMName $VMName -GuestName $guest.name -UserName $UserName
        $shortcut = New-AutoVMShortcut -LauncherPath $panel.LauncherPath -IncludeStartMenu
        $created.Add($shortcut)
        $report.shortcutPath = $shortcut
        $report.acceptance['shortcutPresent'] = (Test-Path -LiteralPath $shortcut)

        Complete-AutoVMPhase -State $state -Id 'P7' -Result 'PASS' -Elapsed ((Get-Date) - $phaseStart) `
            -Created @($shortcut) -Root $root | Out-Null

        $report.acceptance['machineRegistered'] = ((Get-AutoVMVmName) -contains $VMName)
        $report.result = if (@($report.acceptance.Values) -contains $false) { 'PARTIAL' } else { 'SUCCESS' }
        $report.handoverNote = New-AutoVMHandoverNote -Plan $plan -UserName $UserName `
            -ShortcutPath $shortcut -Destroyed $destroyed.ToArray()

        Write-AutoVMLog -Level Success -Percent 100 -Message 'Done.'
        Write-AutoVMLog -Level Info -Message $report.handoverNote
    } catch {
        $report.failure = $_.Exception.Message
        $report.result = 'FAILED'
        Write-AutoVMLog -Level Error -Message $_.Exception.Message
        Complete-AutoVMPhase -State $state -Id $script:AutoVMPhase -Result 'FAIL' `
            -Detail $_.Exception.Message -Elapsed ((Get-Date) - $started) -Root $root | Out-Null
    } finally {
        if ($preseedPath) { Remove-AutoVMFileSecurely -Path $preseedPath }
        Clear-AutoVMSecret

        $report.created = $created.ToArray()
        $report.destroyed = $destroyed.ToArray()
        $report.warnings = @($report.warnings)
        $report.finishedAt = (Get-Date).ToUniversalTime().ToString('o')
        $report.elapsed = ((Get-Date) - $started).ToString('hh\:mm\:ss')

        try {
            $report | ConvertTo-Json -Depth 8 |
                Set-Content -LiteralPath (Join-Path (Join-Path $root 'manifests') 'build-report.json') -Encoding utf8
        } catch {
            Write-AutoVMLog -Level Warn -Message "Could not write the build report: $($_.Exception.Message)"
        }
    }

    return $report
}
