<#
    AutoVM engine module.

    Load order matters: Private first (helpers, pure logic), then Public
    (the orchestration surface the GUI and the CLI both call).
#>
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:AutoVMModuleRoot = $PSScriptRoot

foreach ($folder in 'Private', 'Public') {
    $dir = Join-Path $PSScriptRoot $folder
    if (-not (Test-Path $dir)) { continue }
    foreach ($file in Get-ChildItem -Path $dir -Filter '*.ps1' | Sort-Object Name) {
        . $file.FullName
    }
}
