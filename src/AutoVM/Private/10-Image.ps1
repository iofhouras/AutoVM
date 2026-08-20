<#
    Image acquisition.

    Downloads are resumable and always verified. A hash that does not match is
    treated as a stop, not a retry loop: the whole security value of installing
    a system image rests on this one comparison.
#>

function Get-AutoVMImage {
    <#
        .SYNOPSIS
        Downloads a guest image and verifies it against its published checksum.

        .DESCRIPTION
        An image already in the cache is re-hashed rather than trusted, so a
        resumed run cannot inherit a corrupt file from a previous attempt.

        .PARAMETER Force
        Re-download even when a verified copy is already cached.
    #>
    [CmdletBinding()]
    [OutputType([psobject])]
    param(
        [Parameter(Mandatory)][psobject]$Image,
        [Parameter(Mandatory)][string]$CacheDirectory,
        [switch]$Force
    )

    if (-not (Test-Path -LiteralPath $CacheDirectory)) {
        New-Item -ItemType Directory -Force -Path $CacheDirectory | Out-Null
    }
    $target = Join-Path $CacheDirectory $Image.FileName

    if ((Test-Path -LiteralPath $target) -and -not $Force) {
        Write-AutoVMLog -Level Step -Message 'Checking the image already in the cache' -Percent 32
        if (Test-AutoVMImageHash -Path $target -Expected $Image.Sha256) {
            Write-AutoVMLog -Level Success -Message "Cached image verified: $($Image.FileName)"
            return [pscustomobject]@{ Path = $target; Sha256 = $Image.Sha256; Cached = $true }
        }
        Write-AutoVMLog -Level Warn -Message 'The cached image did not match its checksum and will be downloaded again.'
        Remove-Item -LiteralPath $target -Force -ErrorAction SilentlyContinue
    }

    Save-AutoVMDownload -Url $Image.Url -Destination $target -DisplayName $Image.FileName

    Write-AutoVMLog -Level Step -Message 'Verifying the download' -Percent 40
    if (-not (Test-AutoVMImageHash -Path $target -Expected $Image.Sha256)) {
        $actual = (Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash.ToLowerInvariant()
        $size = [math]::Round((Get-Item -LiteralPath $target).Length / 1GB, 2)
        Remove-Item -LiteralPath $target -Force -ErrorAction SilentlyContinue
        throw ("AUTOVM-P4: The downloaded image does not match the checksum published for it. " +
            "Expected $($Image.Sha256), got $actual (file was $size GB). " +
            'The download was deleted and AutoVM stopped rather than install an image it cannot vouch for.')
    }

    Write-AutoVMLog -Level Success -Message "Image verified: $($Image.FileName)"
    return [pscustomobject]@{ Path = $target; Sha256 = $Image.Sha256; Cached = $false }
}

function Test-AutoVMImageHash {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Expected
    )

    if (-not (Test-Path -LiteralPath $Path)) { return $false }
    $actual = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
    return ($actual -and $actual.ToLowerInvariant() -eq $Expected.ToLowerInvariant())
}

function Save-AutoVMDownload {
    <#
        .SYNOPSIS
        Downloads a file, resuming an interrupted transfer where possible.

        .DESCRIPTION
        Prefers BITS on Windows, which survives a dropped connection and
        reports progress. Falls back to a buffered HTTP read elsewhere, or when
        BITS is unavailable, so the same code path works in CI.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Url,
        [Parameter(Mandatory)][string]$Destination,
        [string]$DisplayName = 'AutoVM download'
    )

    $bits = Get-Command Start-BitsTransfer -ErrorAction SilentlyContinue
    if ($bits) {
        try {
            $existing = Get-BitsTransfer -Name $DisplayName -ErrorAction SilentlyContinue
            if ($existing) {
                Write-AutoVMLog -Level Info -Message 'Resuming the previous download.'
                Resume-BitsTransfer -BitsJob $existing -ErrorAction Stop
                return
            }

            Write-AutoVMLog -Level Step -Message "Downloading $DisplayName" -Percent 34
            $job = Start-BitsTransfer -Source $Url -Destination $Destination -DisplayName $DisplayName `
                -Asynchronous -ErrorAction Stop

            while ($job.JobState -in @('Connecting', 'Transferring', 'Queued', 'TransientError')) {
                Start-Sleep -Seconds 3
                $job = Get-BitsTransfer -JobId $job.JobId
                if ($job.BytesTotal -gt 0) {
                    $pct = [int](100 * $job.BytesTransferred / $job.BytesTotal)
                    Write-AutoVMLog -Level Step -Percent (32 + [int](0.06 * $pct)) -Message (
                        'Downloading {0} - {1:N1} of {2:N1} GB ({3}%)' -f $DisplayName,
                        ($job.BytesTransferred / 1GB), ($job.BytesTotal / 1GB), $pct)
                }
            }

            if ($job.JobState -eq 'Transferred') {
                Complete-BitsTransfer -BitsJob $job
                return
            }

            $reason = $job.ErrorDescription
            Remove-BitsTransfer -BitsJob $job -ErrorAction SilentlyContinue
            throw "the transfer ended in state $($job.JobState): $reason"
        } catch {
            Write-AutoVMLog -Level Warn -Message "Background transfer failed ($($_.Exception.Message)). Retrying with a direct download."
        }
    }

    Write-AutoVMLog -Level Step -Message "Downloading $DisplayName" -Percent 34
    # Windows PowerShell 5.1 does not load System.Net.Http by default.
    if (-not ('System.Net.Http.HttpClient' -as [type])) {
        Add-Type -AssemblyName System.Net.Http -ErrorAction SilentlyContinue
    }
    $client = [System.Net.Http.HttpClient]::new()
    $client.Timeout = [timespan]::FromHours(4)
    try {
        $response = $client.GetAsync($Url, [System.Net.Http.HttpCompletionOption]::ResponseHeadersRead).GetAwaiter().GetResult()
        if (-not $response.IsSuccessStatusCode) { throw "HTTP $([int]$response.StatusCode) from $Url" }

        $total = if ($response.Content.Headers.ContentLength) { [long]$response.Content.Headers.ContentLength } else { 0 }
        $input = $response.Content.ReadAsStreamAsync().GetAwaiter().GetResult()
        $output = [System.IO.File]::Create($Destination)
        try {
            $buffer = New-Object byte[] 1048576
            $read = 0
            $done = 0L
            $lastReport = [datetime]::UtcNow
            while (($read = $input.Read($buffer, 0, $buffer.Length)) -gt 0) {
                $output.Write($buffer, 0, $read)
                $done += $read
                if (([datetime]::UtcNow - $lastReport).TotalSeconds -ge 3) {
                    $lastReport = [datetime]::UtcNow
                    if ($total -gt 0) {
                        $pct = [int](100 * $done / $total)
                        Write-AutoVMLog -Level Step -Percent (32 + [int](0.06 * $pct)) -Message (
                            'Downloading {0} - {1:N1} of {2:N1} GB ({3}%)' -f $DisplayName, ($done / 1GB), ($total / 1GB), $pct)
                    } else {
                        Write-AutoVMLog -Level Step -Message ('Downloading {0} - {1:N1} GB' -f $DisplayName, ($done / 1GB))
                    }
                }
            }
        } finally {
            $output.Dispose()
            $input.Dispose()
        }
    } finally {
        $client.Dispose()
    }
}
