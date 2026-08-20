@{
    RootModule        = 'AutoVM.psm1'
    ModuleVersion     = '1.0.0'
    GUID              = '4f1d9a2e-6c07-4a1b-9a0f-3e6c2b7d15c4'
    Author            = 'AutoVM'
    CompanyName       = 'AutoVM'
    Copyright         = 'MIT'
    Description       = 'Autonomous virtual machine provisioning engine. Profiles the host it runs on, plans a guest that fits it, and drives VirtualBox through an unattended install to a verified, snapshotted, desktop-launchable VM.'
    PowerShellVersion = '5.1'

    FunctionsToExport = @(
        # Device profiling and planning
        'Get-AutoVMHostProfile'
        'Select-AutoVMTargetVolume'
        'New-AutoVMPlan'
        'Format-AutoVMPlanSummary'

        # Pre-flight gates
        'Test-AutoVMGate'
        'Get-AutoVMGateVerdict'

        # Guest catalog and images
        'Get-AutoVMGuestCatalog'
        'Select-AutoVMIsoName'
        'Select-AutoVMChecksum'
        'Resolve-AutoVMImage'
        'Get-AutoVMImage'

        # Credentials and the installer answer file
        'Test-AutoVMUserName'
        'Test-AutoVMPassword'
        'New-AutoVMCredentialPlan'
        'New-AutoVMPreseed'

        # Optional removal of existing machines
        'Get-AutoVMTeardownCandidate'
        'Test-AutoVMProtectedPath'
        'Test-AutoVMExcludedPath'
        'Invoke-AutoVMTeardown'

        # Handover
        'New-AutoVMControlCenter'
        'New-AutoVMShortcut'
        'New-AutoVMHandoverNote'

        # Orchestration, state and diagnostics
        'Invoke-AutoVMBuild'
        'Get-AutoVMRoot'
        'Initialize-AutoVMRoot'
        'New-AutoVMState'
        'Get-AutoVMState'
        'Save-AutoVMState'
        'Complete-AutoVMPhase'
        'Test-AutoVMPhaseComplete'
        'Add-AutoVMDecision'
        'Register-AutoVMProgressSink'
        'Register-AutoVMSecret'
        'Clear-AutoVMSecret'
        'Protect-AutoVMString'
        'Write-AutoVMLog'
        'Get-AutoVMVirtualBoxVersion'
        'Get-AutoVMVmName'
    )
    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()

    PrivateData = @{
        PSData = @{
            Tags       = @('VirtualBox', 'VM', 'Provisioning', 'Kali', 'Debian', 'Automation')
            ProjectUri = 'https://github.com/iofhouras/AutoVM'
            LicenseUri = 'https://github.com/iofhouras/AutoVM/blob/main/LICENSE'
        }
    }
}
