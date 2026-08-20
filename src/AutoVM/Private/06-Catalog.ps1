<#
    The guest catalog and image resolution.

    Filenames are never hardcoded: distributions re-spin on their own schedule
    and a pinned name returns 404 within a quarter. AutoVM reads the current
    directory listing and takes the newest matching image, then verifies it
    against the checksum file published beside it.
#>

function Get-AutoVMGuestCatalog {
    <#
        .SYNOPSIS
        Returns the guest definitions AutoVM can build.

        .PARAMETER Id
        Optional guest id ('kali', 'debian'). Returns all entries when omitted.
    #>
    [CmdletBinding()]
    [OutputType([psobject[]])]
    param([string]$Id)

    $path = Join-Path $script:AutoVMModuleRoot 'Templates/guests.json'
    if (-not (Test-Path -LiteralPath $path)) { throw "Guest catalog missing at $path" }

    $catalog = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
    $guests = @($catalog.guests)

    if ($Id) {
        $match = @($guests | Where-Object { $_.id -eq $Id })
        if (-not $match) { throw "Unknown guest '$Id'. Available: $((($guests).id) -join ', ')" }
        return $match[0]
    }
    return $guests
}

function Select-AutoVMIsoName {
    <#
        .SYNOPSIS
        Picks the newest image name from an HTML directory listing.

        .DESCRIPTION
        Pure string function so it is unit-testable against captured listings.
        Sorts matches by their embedded version, descending, and returns the
        highest - listings are not reliably ordered.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Listing,
        [Parameter(Mandatory)][string]$Pattern
    )

    $matches = [regex]::Matches($Listing, $Pattern) | ForEach-Object { $_.Value } | Sort-Object -Unique
    if (-not $matches) { return $null }

    $ranked = $matches | ForEach-Object {
        $versionText = ([regex]'[0-9]+(\.[0-9]+)+').Match($_).Value
        $version = [version]'0.0'
        if ($versionText) {
            $parts = @($versionText -split '\.') | Select-Object -First 4
            while ($parts.Count -lt 2) { $parts += '0' }
            [void][version]::TryParse(($parts -join '.'), [ref]$version)
        }
        [pscustomobject]@{ Name = $_; Version = $version }
    }

    return ($ranked | Sort-Object Version, Name -Descending | Select-Object -First 1).Name
}

function Select-AutoVMChecksum {
    <#
        .SYNOPSIS
        Extracts the expected SHA256 for a file from a SHA256SUMS document.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Sums,
        [Parameter(Mandatory)][string]$FileName
    )

    foreach ($line in ($Sums -split "`n")) {
        $trimmed = $line.Trim()
        if (-not $trimmed -or $trimmed.StartsWith('#')) { continue }
        if ($trimmed -notmatch [regex]::Escape($FileName)) { continue }

        $hash = ([regex]'\b[0-9a-fA-F]{64}\b').Match($trimmed).Value
        if ($hash) { return $hash.ToLowerInvariant() }
    }
    return $null
}

function Resolve-AutoVMImage {
    <#
        .SYNOPSIS
        Resolves the current image name and its published checksum for a guest.

        .OUTPUTS
        BaseUrl, FileName, Url and Sha256.
    #>
    [CmdletBinding()]
    [OutputType([psobject])]
    param([Parameter(Mandatory)][psobject]$Guest)

    $bases = @($Guest.isoBaseUrl)
    if ($Guest.fallbackBaseUrl) { $bases += $Guest.fallbackBaseUrl }

    $errors = [System.Collections.Generic.List[string]]::new()

    foreach ($base in $bases) {
        try {
            Write-AutoVMLog -Level Info -Message "Looking up the current $($Guest.name) image at $base"
            $listing = (Invoke-WebRequest -Uri $base -UseBasicParsing -TimeoutSec 60).Content
            $name = Select-AutoVMIsoName -Listing $listing -Pattern $Guest.isoPattern
            if (-not $name) { $errors.Add("no image matching the expected name at $base"); continue }

            $sums = (Invoke-WebRequest -Uri ($base + $Guest.checksumFile) -UseBasicParsing -TimeoutSec 60).Content
            $sha = Select-AutoVMChecksum -Sums $sums -FileName $name
            if (-not $sha) { $errors.Add("no checksum for $name at $base"); continue }

            Write-AutoVMLog -Level Success -Message "Selected $name"
            return [pscustomobject]@{
                BaseUrl  = $base
                FileName = $name
                Url      = $base + $name
                Sha256   = $sha
            }
        } catch {
            $errors.Add("$base : $($_.Exception.Message)")
        }
    }

    throw "AUTOVM-P4: Could not resolve a current $($Guest.name) image. Tried: $($errors -join ' | ')"
}
