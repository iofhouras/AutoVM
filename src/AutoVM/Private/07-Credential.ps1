<#
    Credential handling.

    The user types the login they want. Two things then have to be true at once:
    the Debian installer must accept the account name, and the finished guest
    must have the name the user actually asked for.

    The installer validates usernames against a lowercase-only pattern and
    silently drops to an interactive prompt when the value is rejected - which
    turns an unattended install into one that waits forever. So a name with
    capitals is created in lowercase and renamed once the account exists.
#>

$script:AutoVMReservedNames = @(
    'root', 'daemon', 'bin', 'sys', 'sync', 'games', 'man', 'lp', 'mail', 'news',
    'uucp', 'proxy', 'www-data', 'backup', 'list', 'irc', 'gnats', 'nobody',
    'systemd-network', 'systemd-resolve', 'systemd-timesync', 'messagebus',
    'sshd', 'admin', 'adm', 'sudo', 'staff', 'users', 'nogroup'
)

function Test-AutoVMUserName {
    <#
        .SYNOPSIS
        Validates a requested Linux login and reports how it must be created.

        .OUTPUTS
        IsValid, Reason, Normalised (the lowercase form the installer accepts)
        and RequiresRename.
    #>
    [CmdletBinding()]
    [OutputType([psobject])]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$UserName)

    $result = [pscustomobject]@{
        UserName       = $UserName
        Normalised     = ''
        IsValid        = $false
        RequiresRename = $false
        Reason         = ''
    }

    if ([string]::IsNullOrWhiteSpace($UserName)) {
        $result.Reason = 'Enter a login name.'
        return $result
    }
    if ($UserName.Length -gt 32) {
        $result.Reason = 'A login name can be at most 32 characters.'
        return $result
    }
    if ($UserName -notmatch '^[A-Za-z_][A-Za-z0-9_-]*$') {
        $result.Reason = 'Use letters, digits, hyphen and underscore only, starting with a letter or underscore.'
        return $result
    }

    $lower = $UserName.ToLowerInvariant()
    if ($script:AutoVMReservedNames -contains $lower) {
        $result.Reason = "'$UserName' is reserved by the operating system. Choose another name."
        return $result
    }

    $result.Normalised = $lower
    $result.IsValid = $true
    $result.RequiresRename = ($lower -cne $UserName)
    $result.Reason = if ($result.RequiresRename) {
        "The account is created as '$lower' and renamed to '$UserName' at the end of the install. Linux logins are case-sensitive, so you will sign in as '$UserName'."
    } else {
        ''
    }
    return $result
}

function Test-AutoVMPassword {
    <#
        .SYNOPSIS
        Reports whether a password is usable and how weak it is.

        .DESCRIPTION
        AutoVM does not refuse short passwords - the guest is deliberately
        reachable only from this machine - but it does tell the truth about
        them, and it sets the installer's weak-password override when needed so
        the unattended run is not stopped by a confirmation prompt.
    #>
    [CmdletBinding()]
    [OutputType([psobject])]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Password)

    $result = [pscustomobject]@{
        IsValid      = $false
        IsWeak       = $true
        Score        = 0
        Strength     = 'unusable'
        AllowWeak    = $true
        Reason       = ''
    }

    if ([string]::IsNullOrEmpty($Password)) {
        $result.Reason = 'Enter a password.'
        return $result
    }
    if ($Password -match '[\r\n\t]') {
        $result.Reason = 'A password cannot contain tab or newline characters.'
        return $result
    }
    if ($Password.Length -gt 127) {
        $result.Reason = 'A password can be at most 127 characters.'
        return $result
    }

    $result.IsValid = $true

    $score = 0
    if ($Password.Length -ge 8) { $score++ }
    if ($Password.Length -ge 12) { $score++ }
    if ($Password -cmatch '[a-z]' -and $Password -cmatch '[A-Z]') { $score++ }
    if ($Password -match '\d') { $score++ }
    if ($Password -match '[^A-Za-z0-9]') { $score++ }

    $common = @('password', '123456', '12345678', 'qwerty', 'letmein', 'kali', 'toor', 'root', 'admin', 'changeme')
    if ($common -contains $Password.ToLowerInvariant()) { $score = 0 }

    $result.Score = $score
    $result.IsWeak = ($Password.Length -lt 8 -or $score -le 2)
    $result.AllowWeak = $result.IsWeak
    $result.Strength = switch ($score) {
        { $_ -le 1 } { 'very weak' }
        2 { 'weak' }
        3 { 'fair' }
        4 { 'strong' }
        default { 'very strong' }
    }
    if ($result.IsWeak) {
        $result.Reason = 'This password is short or simple. That is acceptable here only because the virtual machine has no inbound network path - change it before putting the machine on a bridged or public network.'
    }
    return $result
}

function New-AutoVMCredentialPlan {
    <#
        .SYNOPSIS
        Combines the login and password checks into the plan the preseed needs.

        .PARAMETER Password
        A SecureString. It is converted to plain text only where the installer
        answer file is written, and that file is shredded afterwards.
    #>
    [CmdletBinding()]
    [OutputType([psobject])]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$UserName,
        [Parameter(Mandatory)][securestring]$Password,
        [string]$FullName
    )

    $nameCheck = Test-AutoVMUserName -UserName $UserName
    $plain = ConvertFrom-AutoVMSecureString -Secure $Password
    try {
        $passwordCheck = Test-AutoVMPassword -Password $plain
    } finally {
        $plain = $null
    }

    return [pscustomobject]@{
        UserName       = $UserName
        InstallerName  = $nameCheck.Normalised
        RequiresRename = $nameCheck.RequiresRename
        FullName       = if ($FullName) { $FullName } else { $UserName }
        Password       = $Password
        IsValid        = ($nameCheck.IsValid -and $passwordCheck.IsValid)
        AllowWeak      = $passwordCheck.AllowWeak
        Strength       = $passwordCheck.Strength
        Notes          = @($nameCheck.Reason, $passwordCheck.Reason | Where-Object { $_ })
    }
}
