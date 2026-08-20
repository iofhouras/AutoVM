<#
    Host environment helpers: where AutoVM keeps its state, whether the session
    is elevated, and the small platform predicates the rest of the engine uses.
#>

function Get-AutoVMRoot {
    <#  The per-machine working directory. Overridable for tests and CI.  #>
    [CmdletBinding()]
    [OutputType([string])]
    param()

    if ($env:AUTOVM_ROOT) { return $env:AUTOVM_ROOT }
    if ($env:ProgramData) { return (Join-Path $env:ProgramData 'AutoVM') }
    return (Join-Path ([System.IO.Path]::GetTempPath()) 'AutoVM')
}

function Initialize-AutoVMRoot {
    [CmdletBinding()]
    [OutputType([string])]
    param([string]$Root = (Get-AutoVMRoot))

    foreach ($sub in @('', 'logs', 'cache', 'manifests', 'run', 'app')) {
        $path = if ($sub) { Join-Path $Root $sub } else { $Root }
        if (-not (Test-Path $path)) { New-Item -ItemType Directory -Force -Path $path | Out-Null }
    }
    return $Root
}

function Test-AutoVMWindows {
    [CmdletBinding()]
    [OutputType([bool])]
    param()

    # $IsWindows exists on PowerShell 6+; on Windows PowerShell 5.1 it does not.
    if (Get-Variable -Name IsWindows -Scope Global -ErrorAction SilentlyContinue) { return [bool]$IsWindows }
    return $true
}

function Test-AutoVMElevated {
    <#  Rule R1 from the directive: phases that touch drivers need elevation.  #>
    [CmdletBinding()]
    [OutputType([bool])]
    param()

    if (-not (Test-AutoVMWindows)) { return $false }
    try {
        $id = [Security.Principal.WindowsIdentity]::GetCurrent()
        return ([Security.Principal.WindowsPrincipal]$id).IsInRole(
            [Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch {
        return $false
    }
}

function Update-AutoVMSessionPath {
    <#
        Re-reads the machine and user PATH into the current process.
        A freshly installed MSI updates the environment block, not the shell
        that launched it, so tools are otherwise unresolvable until restart.
    #>
    [CmdletBinding()]
    param()

    if (-not (Test-AutoVMWindows)) { return }
    $machine = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    $user = [Environment]::GetEnvironmentVariable('Path', 'User')
    $env:Path = (@($machine, $user) | Where-Object { $_ }) -join ';'
}

function ConvertFrom-AutoVMSecureString {
    <#  Reads a SecureString into a plain string for the one moment it is needed.  #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][securestring]$Secure)

    $ptr = [Runtime.InteropServices.Marshal]::SecureStringToGlobalAllocUnicode($Secure)
    try { return [Runtime.InteropServices.Marshal]::PtrToStringUni($ptr) }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeGlobalAllocUnicode($ptr) }
}

function Remove-AutoVMFileSecurely {
    <#
        Overwrites a file's bytes before deleting it.

        Used for the preseed, which necessarily contains the guest password in
        clear text for the duration of the install.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) { return }
    try {
        $length = (Get-Item -LiteralPath $Path).Length
        if ($length -gt 0) {
            $bytes = New-Object byte[] $length
            $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
            try { $rng.GetBytes($bytes) } finally { $rng.Dispose() }
            [System.IO.File]::WriteAllBytes($Path, $bytes)
        }
    } catch {
        Write-AutoVMLog -Level Debug -Message "Secure overwrite failed for $Path : $($_.Exception.Message)"
    } finally {
        Remove-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
    }
}

function Protect-AutoVMDirectory {
    <#  Restricts a directory to SYSTEM and the local Administrators group.  #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-AutoVMWindows)) { return }
    try {
        $acl = Get-Acl -LiteralPath $Path
        $acl.SetAccessRuleProtection($true, $false)
        foreach ($sid in @('S-1-5-18', 'S-1-5-32-544')) {
            $account = [Security.Principal.SecurityIdentifier]::new($sid)
            $rule = [Security.AccessControl.FileSystemAccessRule]::new(
                $account, 'FullControl', 'ContainerInherit,ObjectInherit', 'None', 'Allow')
            $acl.AddAccessRule($rule)
        }
        Set-Acl -LiteralPath $Path -AclObject $acl
    } catch {
        Write-AutoVMLog -Level Warn -Message "Could not restrict permissions on $Path : $($_.Exception.Message)"
    }
}
