<#
    .SYNOPSIS
    Builds the AutoVM launcher and the downloadable installer.

    .DESCRIPTION
    Three steps, all on Windows:

        1. Compile the launcher with the .NET Framework compiler that ships
           with Windows, so the installed application needs no extra runtime.
        2. Stage everything the installer ships into dist\staging.
        3. Compile dist\staging into dist\AutoVM-Setup-<version>.exe with
           Inno Setup.

    .PARAMETER Version
    Version stamped into the launcher, the installer and the output filename.

    .PARAMETER SkipInstaller
    Compile and stage only. Useful when Inno Setup is not present - the staged
    folder is a working, runnable copy of the application.

    .EXAMPLE
    .\build\Build-Installer.ps1 -Version 1.0.0
#>
[CmdletBinding()]
param(
    [string]$Version = '1.0.0',
    [switch]$SkipInstaller,
    [string]$InnoSetupPath
)

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$dist = Join-Path $repo 'dist'
$staging = Join-Path $dist 'staging'

function Write-Step { param([string]$Text) Write-Host "==> $Text" -ForegroundColor Cyan }

if ($IsLinux -or $IsMacOS) { throw 'The installer can only be built on Windows.' }

# ---------------------------------------------------------------- 1. launcher
Write-Step 'Compiling the launcher'

$csc = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
if (-not (Test-Path -LiteralPath $csc)) {
    $csc = Join-Path $env:WINDIR 'Microsoft.NET\Framework\v4.0.30319\csc.exe'
}
if (-not (Test-Path -LiteralPath $csc)) {
    throw "The .NET Framework compiler was not found at $csc. Install the .NET Framework 4.x developer tools."
}

if (Test-Path -LiteralPath $staging) { Remove-Item -LiteralPath $staging -Recurse -Force }
New-Item -ItemType Directory -Force -Path $staging | Out-Null

$assemblyInfo = Join-Path $env:TEMP 'AutoVMAssemblyInfo.cs'
@"
using System.Reflection;
[assembly: AssemblyTitle("AutoVM")]
[assembly: AssemblyProduct("AutoVM")]
[assembly: AssemblyDescription("Sets up a Linux virtual machine on this device")]
[assembly: AssemblyCompany("AutoVM")]
[assembly: AssemblyVersion("$Version.0")]
[assembly: AssemblyFileVersion("$Version.0")]
"@ | Set-Content -LiteralPath $assemblyInfo -Encoding utf8

$launcherExe = Join-Path $staging 'AutoVM.exe'
$cscArgs = @(
    '/nologo'
    '/target:winexe'
    '/optimize+'
    "/out:$launcherExe"
    "/win32icon:$(Join-Path $repo 'src\AutoVM.App\AutoVM.ico')"
    "/win32manifest:$(Join-Path $repo 'src\AutoVM.Launcher\app.manifest')"
    '/reference:System.dll'
    '/reference:System.Windows.Forms.dll'
    "$(Join-Path $repo 'src\AutoVM.Launcher\Launcher.cs')"
    $assemblyInfo
)
& $csc @cscArgs
if ($LASTEXITCODE -ne 0) { throw "The launcher failed to compile (csc exit $LASTEXITCODE)." }
Remove-Item -LiteralPath $assemblyInfo -Force -ErrorAction SilentlyContinue
Write-Host "    $launcherExe"

# ---------------------------------------------------------------- 2. staging
Write-Step 'Staging the application'

Copy-Item -Path (Join-Path $repo 'src\AutoVM.App\AutoVM.ps1') -Destination $staging
Copy-Item -Path (Join-Path $repo 'src\AutoVM.App\AutoVM.Console.ps1') -Destination $staging
Copy-Item -Path (Join-Path $repo 'src\AutoVM.App\MainWindow.xaml') -Destination $staging
Copy-Item -Path (Join-Path $repo 'src\AutoVM.App\AutoVM.ico') -Destination $staging
Copy-Item -Path (Join-Path $repo 'src\AutoVM') -Destination $staging -Recurse

Copy-Item -Path (Join-Path $repo 'LICENSE') -Destination (Join-Path $staging 'LICENSE.txt')
Copy-Item -Path (Join-Path $repo 'docs\INSTALL.txt') -Destination (Join-Path $staging 'README.txt')

$docs = Join-Path $staging 'docs'
New-Item -ItemType Directory -Force -Path $docs | Out-Null
$directive = Join-Path $repo 'docs\agent-directive\KaliVMAgentDirective-v2.pdf'
if (Test-Path -LiteralPath $directive) { Copy-Item -Path $directive -Destination $docs }

# The staged tree is a runnable copy; prove the engine still loads from it.
Import-Module (Join-Path $staging 'AutoVM\AutoVM.psd1') -Force
$exported = (Get-Command -Module AutoVM).Count
Remove-Module AutoVM -Force
Write-Host "    staged, engine exports $exported commands"

# ---------------------------------------------------------------- 3. installer
if ($SkipInstaller) {
    Write-Step "Skipping the installer. The application is ready in $staging"
    return
}

Write-Step 'Building the installer'

if (-not $InnoSetupPath) {
    foreach ($candidate in @(
            "${env:ProgramFiles(x86)}\Inno Setup 6\ISCC.exe",
            "$env:ProgramFiles\Inno Setup 6\ISCC.exe"
        )) {
        if (Test-Path -LiteralPath $candidate) { $InnoSetupPath = $candidate; break }
    }
}
if (-not $InnoSetupPath -or -not (Test-Path -LiteralPath $InnoSetupPath)) {
    throw 'Inno Setup 6 was not found. Install it (winget install JRSoftware.InnoSetup) or pass -InnoSetupPath.'
}

& $InnoSetupPath (Join-Path $PSScriptRoot 'AutoVM.iss') `
    "/DAppVersion=$Version" "/DSourceDir=$staging" "/DOutputDir=$dist"
if ($LASTEXITCODE -ne 0) { throw "Inno Setup failed (exit $LASTEXITCODE)." }

$setup = Join-Path $dist "AutoVM-Setup-$Version.exe"
$size = [math]::Round((Get-Item -LiteralPath $setup).Length / 1MB, 1)
Write-Step "Done: $setup ($size MB)"
