<#
    Optional cleanup of existing virtual machines.

    This is the only part of AutoVM that can destroy something the user cares
    about, so it is off unless asked for, it never runs without a typed
    confirmation, and several classes of file are never offered for deletion at
    all - most importantly WSL disks, which for many people hold the only copy
    of work that was never committed anywhere.
#>

$script:AutoVMProtectedPatterns = @(
    '\\AppData\\Local\\Packages\\.*\\ext4\.vhdx$',   # WSL distributions
    '\\Windows\.old\\',
    '\\Recovery\\',
    '\\\$WinREAgent\\',
    'WindowsSandbox',
    '\\System Volume Information\\'
)

$script:AutoVMExcludedPatterns = @(
    '\\Windows\\', '\\Program Files', '\\ProgramData\\Microsoft\\',
    '\\OneDrive', 'CanonicalGroupLimited', '\\docker\\', '\\WpSystem\\'
)

function Test-AutoVMProtectedPath {
    <#
        .SYNOPSIS
        True when a path belongs to a class AutoVM must never delete.

        .DESCRIPTION
        Pure string test so the protection rules can be unit-tested directly.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$Path,
        [string[]]$MountedImages = @()
    )

    foreach ($pattern in $script:AutoVMProtectedPatterns) {
        if ($Path -match $pattern) { return $true }
    }
    if ($MountedImages -contains $Path) { return $true }
    return $false
}

function Test-AutoVMExcludedPath {
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][string]$Path)

    foreach ($pattern in $script:AutoVMExcludedPatterns) {
        if ($Path -match $pattern) { return $true }
    }
    return $false
}

function Get-AutoVMTeardownCandidate {
    <#
        .SYNOPSIS
        Inventories existing virtual machines and disk images. Read-only.

        .OUTPUTS
        One record per candidate with its size and whether it is protected.
    #>
    [CmdletBinding()]
    [OutputType([psobject[]])]
    param(
        [string[]]$SearchRoots,
        [switch]$IncludeLooseImages
    )

    $candidates = [System.Collections.Generic.List[psobject]]::new()

    foreach ($vm in (Get-AutoVMVmName)) {
        $cfg = Get-AutoVMVmProperty -VMName $vm -Key 'CfgFile'
        $candidates.Add([pscustomobject]@{
                Kind      = 'RegisteredVM'
                Name      = $vm
                Path      = $cfg
                SizeGB    = 0
                Protected = $false
            })
    }

    if ($IncludeLooseImages) {
        $mounted = @()
        try { $mounted = @((Get-DiskImage -ErrorAction SilentlyContinue | Where-Object Attached).ImagePath) } catch { }

        if (-not $SearchRoots) {
            $SearchRoots = @(
                (Join-Path $env:USERPROFILE 'VirtualBox VMs')
                (Join-Path $env:USERPROFILE 'Documents\Virtual Machines')
            ) | Where-Object { $_ -and (Test-Path -LiteralPath $_) }
        }

        $extensions = @('*.vbox', '*.vdi', '*.vmdk', '*.vhd', '*.vhdx', '*.ova', '*.qcow2')
        foreach ($root in $SearchRoots) {
            Get-ChildItem -LiteralPath $root -Recurse -File -Force -ErrorAction SilentlyContinue -Include $extensions |
                ForEach-Object {
                    $path = $_.FullName
                    if (Test-AutoVMExcludedPath -Path $path) { return }
                    $candidates.Add([pscustomobject]@{
                            Kind      = 'DiskImage'
                            Name      = $_.Name
                            Path      = $path
                            SizeGB    = [math]::Round($_.Length / 1GB, 2)
                            Protected = (Test-AutoVMProtectedPath -Path $path -MountedImages $mounted)
                        })
                }
        }
    }

    return $candidates.ToArray()
}

function Invoke-AutoVMTeardown {
    <#
        .SYNOPSIS
        Removes the candidates the caller confirmed. Requires an explicit consent token.

        .PARAMETER Confirmation
        Must be exactly 'DESTROY', compared case-sensitively. Nothing else - not
        'yes', not an empty prompt, not a timeout - authorises deletion.
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][psobject[]]$Candidates,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Confirmation
    )

    if ($Confirmation -cne 'DESTROY') {
        throw 'AUTOVM-R4: Removal was not confirmed. Nothing has been deleted.'
    }

    $destroyed = [System.Collections.Generic.List[string]]::new()
    $doomed = @($Candidates | Where-Object { -not $_.Protected })
    $kept = @($Candidates | Where-Object { $_.Protected })

    foreach ($item in $kept) {
        Write-AutoVMLog -Level Info -Message "Keeping protected item: $($item.Path)"
    }

    foreach ($item in ($doomed | Where-Object { $_.Kind -eq 'RegisteredVM' })) {
        if (-not $PSCmdlet.ShouldProcess($item.Name, 'unregister and delete virtual machine')) { continue }
        Write-AutoVMLog -Level Warn -Message "Removing virtual machine '$($item.Name)'"
        Invoke-VBoxManage -Arguments @('controlvm', $item.Name, 'poweroff') -IgnoreExitCode | Out-Null
        Start-Sleep -Seconds 2
        Invoke-VBoxManage -Arguments @('unregistervm', $item.Name, '--delete') -IgnoreExitCode | Out-Null
        $destroyed.Add($item.Name)
    }

    foreach ($item in ($doomed | Where-Object { $_.Kind -eq 'DiskImage' })) {
        if (-not $PSCmdlet.ShouldProcess($item.Path, 'delete disk image')) { continue }
        if (-not (Test-Path -LiteralPath $item.Path)) { continue }
        Write-AutoVMLog -Level Warn -Message "Deleting $($item.Path)"
        Remove-Item -LiteralPath $item.Path -Force -ErrorAction Continue
        $destroyed.Add($item.Path)
    }

    Write-AutoVMLog -Level Success -Message "Removed $($destroyed.Count) item(s); kept $($kept.Count) protected item(s)."
    return $destroyed.ToArray()
}
