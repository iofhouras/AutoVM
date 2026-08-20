<#
    .SYNOPSIS
    AutoVM without the wizard - for scripted or repeated builds.

    .DESCRIPTION
    Same engine, same phases, same safety rules as the desktop application.
    Useful for setting up several identical machines, or for running the build
    from a deployment script.

    .PARAMETER Plan
    Profile the device and print what would be built, then stop.

    .EXAMPLE
    .\AutoVM.Console.ps1 -UserName analyst
    Prompts for the password, then builds a Kali guest sized for this device.

    .EXAMPLE
    .\AutoVM.Console.ps1 -UserName dev -GuestId debian -Plan
    Prints the plan for a Debian guest and changes nothing.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][string]$UserName,
    [securestring]$Password,
    [ValidateSet('kali', 'debian')][string]$GuestId = 'kali',
    [string]$VMName,
    [ValidateSet('Auto', 'Light', 'Full')][string]$Profile = 'Auto',
    [switch]$Headless,
    [switch]$Plan,
    [switch]$AcceptDegradedVirtualization,
    [int]$InstallTimeoutMinutes = 90,
    [string]$ModulePath
)

$ErrorActionPreference = 'Stop'

if (-not $ModulePath) {
    $appRoot = Split-Path -Parent $PSCommandPath
    foreach ($candidate in @(
            (Join-Path $appRoot 'AutoVM\AutoVM.psd1'),
            (Join-Path $appRoot '..\AutoVM\AutoVM.psd1')
        )) {
        if (Test-Path -LiteralPath $candidate) { $ModulePath = (Resolve-Path $candidate).Path; break }
    }
}
Import-Module $ModulePath -Force

if (-not $Password) { $Password = Read-Host "Password for '$UserName' inside the virtual machine" -AsSecureString }

$options = @{
    UserName              = $UserName
    Password              = $Password
    GuestId               = $GuestId
    Profile               = $Profile
    InstallTimeoutMinutes = $InstallTimeoutMinutes
}
if ($VMName) { $options['VMName'] = $VMName }
if ($Headless) { $options['Headless'] = $true }
if ($Plan) { $options['WhatIfPlanOnly'] = $true }
if ($AcceptDegradedVirtualization) { $options['AcceptDegradedVirtualization'] = $true }

$report = Invoke-AutoVMBuild @options

Write-Host ''
Write-Host ("Result: {0}" -f $report.result) -ForegroundColor $(
    switch ($report.result) { 'SUCCESS' { 'Green' } 'PLANNED' { 'Cyan' } 'PARTIAL' { 'Yellow' } default { 'Red' } })

if ($report.plan) { Write-Host ("Plan:   {0}" -f (Format-AutoVMPlanSummary -Plan $report.plan)) }
foreach ($warning in $report.warnings) { Write-Host "Note:   $warning" -ForegroundColor Yellow }
if ($report.failure) { Write-Host "Stopped: $($report.failure)" -ForegroundColor Red }
if ($report.handoverNote) { Write-Host ''; Write-Host $report.handoverNote }

exit $(if ($report.result -in @('SUCCESS', 'PLANNED')) { 0 } else { 1 })
