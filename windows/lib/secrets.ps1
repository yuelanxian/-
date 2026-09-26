# HomeVault Windows CLI - secrets (CSPRNG, never regenerated) and private ACLs.

$script:HvSecretNames = @('postgres_password', 'redis_password', 'nextcloud_admin_password', 'restic_password')

$script:HvSidSystem = 'S-1-5-18'
$script:HvSidAdmins = 'S-1-5-32-544'

function Get-HvSecretsDir { return (Get-HvPath 'secrets') }

function Get-HvIcaclsArgs {
    # Pure: icacls arguments that replace inherited ACEs with SYSTEM + Administrators (full) + user(s).
    param([string]$Path, [string[]]$UserSids = @(), [switch]$Directory, [switch]$UserReadOnly)
    $inh = ''
    if ($Directory) { $inh = '(OI)(CI)' }
    $userRight = 'F'
    if ($UserReadOnly) { $userRight = 'RX' }
    $a = @($Path, '/inheritance:r', '/grant:r', ('*' + $script:HvSidSystem + ':' + $inh + 'F'), ('*' + $script:HvSidAdmins + ':' + $inh + 'F'))
    foreach ($sid in @($UserSids)) { if ($sid) { $a += ('*' + $sid + ':' + $inh + $userRight) } }
    $a += '/Q'
    return $a
}

function Get-HvDesktopUserName {
    # The user signed in at the console (runs Docker Desktop); differs from the current identity when
    # install was elevated with another administrator account.
    if (-not (Test-HvWindows)) { return (Get-HvCurrentUserName) }
    try {
        $u = [string](Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop).UserName
        if ($u) { return $u }
    } catch { }
    return (Get-HvCurrentUserName)
}

function Get-HvUserSids {
    # Current user + console user (deduplicated).
    $sids = @()
    $cur = Get-HvCurrentUserSid
    if ($cur) { $sids += $cur }
    $desk = Get-HvDesktopUserName
    if ($desk -and $desk -ne (Get-HvCurrentUserName)) {
        try {
            $s = (New-Object System.Security.Principal.NTAccount($desk)).Translate([System.Security.Principal.SecurityIdentifier]).Value
            if ($sids -notcontains $s) { $sids += $s }
        } catch { }
    }
    return $sids
}

function Set-HvPrivateAcl {
    # Restrict a file/dir to SYSTEM + Administrators + the current/console user. No-op outside Windows.
    # Skipped when already private (re-install on a large data folder stays fast).
    # -ResetChildren: make existing children inherit again (small folders such as secrets\ only).
    param([Parameter(Mandatory = $true)][string]$Path, [switch]$UserReadOnly, [switch]$ResetChildren)
    if (-not (Test-HvWindows)) { return }
    if (-not (Test-Path -LiteralPath $Path)) { return }
    if (-not $UserReadOnly -and (Test-HvPrivateAcl $Path)) { return }
    $isDir = [System.IO.Directory]::Exists($Path)
    $a = Get-HvIcaclsArgs -Path $Path -UserSids (Get-HvUserSids) -Directory:$isDir -UserReadOnly:$UserReadOnly
    $r = Invoke-HvNative -FilePath 'icacls.exe' -ArgumentList $a -Capture -AllowFailure
    if ($r.ExitCode -ne 0) { Write-HvWarn ('设置权限失败：' + $Path + ' ' + ($r.StdErr -join ' ')); return }
    if ($isDir -and $ResetChildren) {
        $children = @(Get-ChildItem -LiteralPath $Path -Force -ErrorAction SilentlyContinue)
        if ($children.Count -gt 0) {
            [void](Invoke-HvNative -FilePath 'icacls.exe' -ArgumentList @((Join-HvPath $Path '*'), '/reset', '/T', '/C', '/Q') -Capture -AllowFailure)
        }
    }
}

function Test-HvPrivateAcl {
    # True when only SYSTEM / Administrators / the current user have access and inheritance is off.
    param([string]$Path)
    if (-not (Test-HvWindows)) { return $true }
    if (-not (Test-Path -LiteralPath $Path)) { return $false }
    $acl = Get-Acl -LiteralPath $Path
    if (-not $acl.AreAccessRulesProtected) { return $false }
    $allowed = @($script:HvSidSystem, $script:HvSidAdmins) + @(Get-HvUserSids)
    foreach ($rule in $acl.GetAccessRules($true, $true, [System.Security.Principal.SecurityIdentifier])) {
        if ($rule.AccessControlType -ne 'Allow') { continue }
        if ($allowed -notcontains $rule.IdentityReference.Value) { return $false }
    }
    return $true
}

function Initialize-HvSecretsDir {
    $dir = New-HvDirectory (Get-HvSecretsDir)
    Set-HvPrivateAcl -Path $dir -ResetChildren
    return $dir
}

function Get-HvSecretPath { param([string]$Name) return (Join-HvPath (Get-HvSecretsDir) $Name) }

function Test-HvSecret {
    param([string]$Name)
    $p = Get-HvSecretPath $Name
    if (-not [System.IO.File]::Exists($p)) { return $false }
    return ((Read-HvTextFile $p).Trim() -ne '')
}

function Read-HvSecret {
    param([string]$Name)
    $p = Get-HvSecretPath $Name
    if (-not [System.IO.File]::Exists($p)) { return '' }
    return (Read-HvTextFile $p).Trim()
}

function Write-HvSecret {
    # One secret per file, no trailing newline (read via *_FILE by the containers).
    param([string]$Name, [string]$Value)
    [void](Initialize-HvSecretsDir)
    Write-HvTextFile -Path (Get-HvSecretPath $Name) -Content $Value
}

function Initialize-HvSecrets {
    # Generate missing secrets only (re-install / upgrade safe). Returns the names generated now.
    [void](Initialize-HvSecretsDir)
    $created = @()
    foreach ($n in $script:HvSecretNames) {
        if (-not (Test-HvSecret $n)) {
            Write-HvSecret -Name $n -Value (New-HvRandomString 32)
            $created += $n
        }
    }
    Set-HvPrivateAcl -Path (Get-HvSecretsDir) -ResetChildren
    return $created
}

function ConvertTo-HvEnvFileText {
    # KEY=value lines for secrets/*.env files consumed by compose env_file.
    param([System.Collections.IDictionary]$Values)
    $lines = @()
    foreach ($k in $Values.Keys) { $lines += ([string]$k + '=' + (Format-HvEnvValue ([string]$Values[$k]))) }
    return (($lines -join "`n") + "`n")
}
