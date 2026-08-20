<#
    The resume ledger.

    Every phase writes its outcome here before the next one starts, so a run
    that is interrupted (sleep, reboot, closed window) resumes at the next
    incomplete phase instead of starting over — which matters most because the
    only destructive phase must never be repeated by accident.
#>

function Get-AutoVMStatePath {
    [CmdletBinding()]
    [OutputType([string])]
    param([string]$Root = (Get-AutoVMRoot))
    return (Join-Path $Root 'state.json')
}

function New-AutoVMState {
    [CmdletBinding()]
    param(
        [string]$Root = (Get-AutoVMRoot),
        [string]$BuildId
    )

    if (-not $BuildId) { $BuildId = 'autovm-{0}' -f (Get-Date -Format 'yyyyMMdd-HHmmss') }

    return [pscustomobject]@{
        buildId   = $BuildId
        schema    = 2
        startedAt = (Get-Date).ToUniversalTime().ToString('o')
        root      = $Root
        completed = @()
        decisions = @()
        artifacts = [pscustomobject]@{ isoPath = ''; isoSha256 = ''; vmDir = ''; vmName = '' }
    }
}

function Get-AutoVMState {
    <#
        .SYNOPSIS
        Loads the resume ledger, or creates a fresh one when none exists.
    #>
    [CmdletBinding()]
    param([string]$Root = (Get-AutoVMRoot))

    $path = Get-AutoVMStatePath -Root $Root
    if (Test-Path -LiteralPath $path) {
        try {
            $state = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
            if ($state.PSObject.Properties.Name -contains 'buildId') { return $state }
        } catch {
            Write-AutoVMLog -Level Warn -Message "state.json is unreadable, starting a fresh ledger: $($_.Exception.Message)"
        }
    }
    return (New-AutoVMState -Root $Root)
}

function Save-AutoVMState {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][psobject]$State,
        [string]$Root = (Get-AutoVMRoot)
    )

    $path = Get-AutoVMStatePath -Root $Root
    $State | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $path -Encoding utf8
}

function Complete-AutoVMPhase {
    <#
        .SYNOPSIS
        Records a phase outcome and persists the ledger immediately.

        .DESCRIPTION
        The six fields recorded here are the per-phase report the directive
        requires: id, result, artifacts created, artifacts destroyed, elapsed
        time and the timestamp.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][psobject]$State,
        [Parameter(Mandatory)][string]$Id,
        [Parameter(Mandatory)][ValidateSet('PASS', 'FAIL', 'SKIPPED')][string]$Result,
        [string[]]$Created = @(),
        [string[]]$Destroyed = @(),
        [timespan]$Elapsed = [timespan]::Zero,
        [string]$Detail = '',
        [string]$Root = (Get-AutoVMRoot)
    )

    $entry = [pscustomobject]@{
        id        = $Id
        result    = $Result
        created   = @($Created)
        destroyed = @($Destroyed)
        elapsed   = $Elapsed.ToString('hh\:mm\:ss')
        detail    = $Detail
        at        = (Get-Date).ToUniversalTime().ToString('o')
    }

    $State.completed = @(@($State.completed) | Where-Object { $_ -and $_.id -ne $Id }) + @($entry)
    Save-AutoVMState -State $State -Root $Root

    Write-AutoVMLog -Level Phase -Message (
        '{0} {1} - created {2}, destroyed {3}, elapsed {4}' -f $Id, $Result, $entry.created.Count, $entry.destroyed.Count, $entry.elapsed
    ) -Data @{ phase = $Id; result = $Result }

    return $entry
}

function Test-AutoVMPhaseComplete {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][psobject]$State,
        [Parameter(Mandatory)][string]$Id
    )

    $match = @($State.completed) | Where-Object { $_ -and $_.id -eq $Id -and $_.result -eq 'PASS' }
    return [bool]$match
}

function Add-AutoVMDecision {
    <#  Records an operator answer to a gate that asks rather than halts.  #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][psobject]$State,
        [Parameter(Mandatory)][string]$Gate,
        [Parameter(Mandatory)][string]$Question,
        [Parameter(Mandatory)][string]$Answer,
        [string]$Root = (Get-AutoVMRoot)
    )

    $State.decisions = @($State.decisions) + @([pscustomobject]@{
            gate     = $Gate
            question = $Question
            answer   = $Answer
            at       = (Get-Date).ToUniversalTime().ToString('o')
        })
    Save-AutoVMState -State $State -Root $Root
}
