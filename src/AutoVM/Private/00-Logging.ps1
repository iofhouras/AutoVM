<#
    Structured logging with secret redaction and a pluggable progress sink.

    Every line the engine emits goes through Write-AutoVMLog, which:
      * redacts registered secrets before anything reaches disk or the console,
      * appends to the run log,
      * forwards a structured record to the progress sink so the GUI can render it.
#>

$script:AutoVMLogPath = $null
$script:AutoVMSecrets = [System.Collections.Generic.List[string]]::new()
$script:AutoVMProgressSink = $null
$script:AutoVMPhase = 'init'

function Register-AutoVMSecret {
    <#  Registers a value that must never appear in a log line.  #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Value)

    if ([string]::IsNullOrEmpty($Value)) { return }
    if (-not $script:AutoVMSecrets.Contains($Value)) { $script:AutoVMSecrets.Add($Value) }
}

function Clear-AutoVMSecret {
    [CmdletBinding()]
    param()
    $script:AutoVMSecrets.Clear()
}

function Protect-AutoVMString {
    <#  Replaces every registered secret in a string with a fixed mask.  #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(ValueFromPipeline)][AllowEmptyString()][string]$Text)

    process {
        if ([string]::IsNullOrEmpty($Text)) { return $Text }
        $out = $Text
        foreach ($secret in $script:AutoVMSecrets) {
            if ($secret.Length -ge 1) { $out = $out.Replace($secret, '********') }
        }
        return $out
    }
}

function Register-AutoVMProgressSink {
    <#
        .SYNOPSIS
        Attaches a callback that receives every structured log record.

        .DESCRIPTION
        The WPF front end registers a sink that pushes records onto a
        synchronised queue; the UI thread drains that queue on a timer. The CLI
        registers nothing and relies on console output.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowNull()][scriptblock]$Sink)

    $script:AutoVMProgressSink = $Sink
}

function Initialize-AutoVMLog {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Root,
        [string]$BuildId
    )

    $logDir = Join-Path $Root 'logs'
    if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Force -Path $logDir | Out-Null }

    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $name = if ($BuildId) { "$BuildId.log" } else { "autovm-$stamp.log" }
    $script:AutoVMLogPath = Join-Path $logDir $name

    Write-AutoVMLog -Level Info -Message "AutoVM log opened at $script:AutoVMLogPath"
    return $script:AutoVMLogPath
}

function Set-AutoVMPhase {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Phase)
    $script:AutoVMPhase = $Phase
}

function Write-AutoVMLog {
    <#
        .SYNOPSIS
        Emits one structured, redacted log record.

        .PARAMETER Level
        Info, Warn, Error, Success, Gate, Phase or Step. The front end maps these
        onto colours; Step drives the wizard's progress list.

        .PARAMETER Percent
        Optional 0-100 completion for the current phase, forwarded to the sink.
    #>
    [CmdletBinding()]
    param(
        [ValidateSet('Info', 'Warn', 'Error', 'Success', 'Gate', 'Phase', 'Step', 'Debug')]
        [string]$Level = 'Info',

        [Parameter(Mandatory, Position = 0)][AllowEmptyString()][string]$Message,

        [hashtable]$Data,
        [ValidateRange(-1, 100)][int]$Percent = -1
    )

    $safe = Protect-AutoVMString $Message
    $record = [pscustomobject]@{
        Timestamp = [datetime]::UtcNow
        Level     = $Level
        Phase     = $script:AutoVMPhase
        Message   = $safe
        Data      = $Data
        Percent   = $Percent
    }

    $line = '{0} [{1,-7}] {2,-10} {3}' -f $record.Timestamp.ToString('HH:mm:ss'), $Level, $record.Phase, $safe

    if ($script:AutoVMLogPath) {
        try { Add-Content -LiteralPath $script:AutoVMLogPath -Value $line -Encoding utf8 } catch { }
    }

    switch ($Level) {
        'Error'   { Write-Host $line -ForegroundColor Red }
        'Warn'    { Write-Host $line -ForegroundColor Yellow }
        'Success' { Write-Host $line -ForegroundColor Green }
        'Gate'    { Write-Host $line -ForegroundColor Magenta }
        'Phase'   { Write-Host $line -ForegroundColor Cyan }
        'Debug'   { Write-Verbose $line }
        default   { Write-Host $line }
    }

    if ($script:AutoVMProgressSink) {
        try { & $script:AutoVMProgressSink $record } catch { }
    }
}
