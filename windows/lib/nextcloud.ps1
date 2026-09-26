# HomeVault Windows CLI - Nextcloud helpers: occ, harden, user management, CA export.

$script:HvCaPathInContainer = '/data/caddy/pki/authorities/local/root.crt'

function Invoke-HvCmdOcc {
    param([object[]]$Arguments = @())
    [void](Get-HvEnv)
    $argv = @()
    foreach ($a in @($Arguments)) { $argv += (ConvertTo-HvArgString $a) }
    $tty = (Test-HvInteractive)
    try { if ([System.Console]::IsOutputRedirected) { $tty = $false } } catch { }
    $r = Invoke-HvOcc -OccArgs $argv -Tty:$tty -AllowFailure
    if ($r.ExitCode -ne 0) { $script:HvExitCode = $r.ExitCode }
}

function Show-HvHardeningSummary {
    $checks = @(
        @{ Label = '强制两步验证（TOTP）'; Args = @('config:system:get', 'twofactor_enforced'); Want = 'true' },
        @{ Label = '强制应用密码（token_auth_enforced）'; Args = @('config:system:get', 'token_auth_enforced'); Want = 'true' },
        @{ Label = '公开分享链接'; Args = @('config:app:get', 'core', 'shareapi_allow_links'); Want = '' },
        @{ Label = '网页端创建本地外部存储'; Args = @('config:system:get', 'files_external_allow_create_new_local'); Want = 'false' }
    )
    $publicWanted = 'no'
    if (Test-HvTrue (Get-HvEnvValue 'HV_ALLOW_PUBLIC_LINKS' 'false')) { $publicWanted = 'yes' }
    foreach ($c in $checks) {
        $v = Get-HvOccValue $c.Args
        $want = $c.Want
        if ($c.Label -eq '公开分享链接') { $want = $publicWanted }
        if ($null -eq $v) { $v = '(未设置)' }
        if ($v -eq $want) { Write-HvOk ($c.Label + '：' + $v) } else { Write-HvWarn ($c.Label + '：' + $v + '（期望 ' + $want + '）') }
    }
    $audit = Invoke-HvOcc -OccArgs @('app:list', '--output=json') -Capture -AllowFailure
    if ($audit.ExitCode -eq 0) {
        $j = $null
        try { $j = ConvertFrom-Json -InputObject (Get-HvJsonSlice $audit.Text) } catch { }
        if ($j) {
            $enabled = Get-HvPropValue $j 'enabled'
            if ($enabled -and ($enabled.PSObject.Properties.Name -contains 'admin_audit')) { Write-HvOk '审计日志（admin_audit）：已启用' } else { Write-HvWarn '审计日志（admin_audit）：未启用' }
        }
    }
}

function Invoke-HvCmdHarden {
    param([object[]]$Arguments = @())
    [void](Read-HvCommandArgs -Arguments $Arguments)
    [void](Get-HvEnv)
    if (-not (Test-HvAppRunning)) { Stop-Hv 'Nextcloud 未运行：请先运行 .\windows\hv.ps1 up' }
    Write-HvStep '重新执行安全加固脚本（before-starting hook）...'
    $r = Invoke-HvCompose -Arguments @('exec', '-T', '-u', 'www-data', 'app', '/docker-entrypoint-hooks.d/before-starting/10-homevault.sh') -AllowFailure
    if ($r.ExitCode -ne 0) { Stop-Hv ('加固脚本执行失败（退出码 ' + $r.ExitCode + '）。') $r.ExitCode }
    Write-HvStep '关键安全设置'
    Show-HvHardeningSummary
}

# ---------------------------------------------------------------- users

function ConvertTo-HvQuota {
    # Accept "500GB", "500 GB", "none", or a byte count (PowerShell turns unquoted 500GB into bytes).
    param([string]$Text)
    $t = $Text.Trim()
    if ($t -match '^(?i)(none|default)$') { return $t.ToLowerInvariant() }
    if ($t -match '^\d+$') { return $t }
    if ($t -match '^(?i)(\d+(?:\.\d+)?)\s*(B|KB|MB|GB|TB)$') { return ($Matches[1] + ' ' + $Matches[2].ToUpperInvariant()) }
    throw ('无效的配额：' + $Text + '（例如 500GB、1TB、none）')
}

function Test-HvUserName {
    param([AllowEmptyString()][string]$Name)
    return ($Name -match '^[A-Za-z0-9_.@-][A-Za-z0-9 _.@''-]{0,63}$')
}

function Invoke-HvCmdUser {
    param([object[]]$Arguments = @())
    $p = Read-HvCommandArgs -Arguments $Arguments -Switches @('admin') -Options @('quota', 'display-name', 'email')
    [void](Get-HvEnv)
    $sub = ''; $name = ''
    if ($p.Positional.Count -gt 0) { $sub = $p.Positional[0] }
    if ($p.Positional.Count -gt 1) { $name = $p.Positional[1] }
    switch ($sub) {
        'list' { [void](Invoke-HvOcc -OccArgs @('user:list')) }
        'add' {
            if (-not (Test-HvUserName $name)) { Stop-Hv '用法：user add <用户名> [--admin] [--quota 500GB] [--display-name 名字]（用户名只能用字母、数字和 _ . @ -）' 2 }
            $quota = $null
            $q = Get-HvOpt $p 'quota' ''
            if ($q) { try { $quota = ConvertTo-HvQuota $q } catch { Stop-Hv $_.Exception.Message 2 } }
            $pw = New-HvRandomString 20
            $occ = @('user:add', '--password-from-env')
            $dn = Get-HvOpt $p 'display-name' ''
            if ($dn) { $occ += ('--display-name=' + $dn) }
            $em = Get-HvOpt $p 'email' ''
            if ($em) { $occ += ('--email=' + $em) }
            if (Test-HvOpt $p 'admin') { $occ += '--group=admin' }
            $occ += $name
            $env:OC_PASS = $pw
            try { [void](Invoke-HvOcc -OccArgs $occ -PassEnv @('OC_PASS')) } finally { Remove-Item Env:\OC_PASS -ErrorAction SilentlyContinue }
            if ($quota) { [void](Invoke-HvOcc -OccArgs @('user:setting', $name, 'files', 'quota', $quota)) }
            Write-HvOk ('已创建用户 ' + $name)
            Write-Host ''
            Write-Host ('  用户名：' + $name)
            Write-Host ('  初始密码（只显示这一次）：' + $pw) -ForegroundColor Yellow
            Write-Host ''
            Write-HvInfo '首次登录会要求设置两步验证（TOTP，例如 Microsoft Authenticator / FreeOTP）。'
            Write-HvInfo '手机和电脑客户端请使用“应用密码”：网页右上角头像 → 个人设置 → 安全 → 创建新应用密码。'
        }
        'reset-2fa' {
            if (-not $name) { Stop-Hv '用法：user reset-2fa <用户名>' 2 }
            [void](Invoke-HvOcc -OccArgs @('twofactorauth:disable', $name, 'totp'))
            Write-HvOk ($name + ' 的 TOTP 已重置：下次登录时会要求重新绑定验证器。')
        }
        'reset-password' {
            if (-not $name) { Stop-Hv '用法：user reset-password <用户名>' 2 }
            $pw = New-HvRandomString 20
            $env:OC_PASS = $pw
            try { [void](Invoke-HvOcc -OccArgs @('user:resetpassword', '--password-from-env', $name) -PassEnv @('OC_PASS')) } finally { Remove-Item Env:\OC_PASS -ErrorAction SilentlyContinue }
            Write-HvOk ('已重置 ' + $name + ' 的密码。')
            Write-Host ('  新密码（只显示这一次）：' + $pw) -ForegroundColor Yellow
        }
        default { Stop-Hv '用法：user add <名> [--admin] [--quota 500GB] [--display-name 名字] | user list | user reset-2fa <名> | user reset-password <名>' 2 }
    }
}

# ---------------------------------------------------------------- CA

function Get-HvCertFingerprint {
    param([string]$Path)
    $cert = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2($Path)
    $hex = (Get-HvBytesSha256Hex $cert.RawData).ToUpperInvariant()
    $pairs = @()
    for ($i = 0; $i -lt $hex.Length; $i += 2) { $pairs += $hex.Substring($i, 2) }
    return [pscustomobject]@{ Fingerprint = ($pairs -join ':'); Subject = $cert.Subject; NotAfter = $cert.NotAfter }
}

function Export-HvCa {
    # Copy Caddy's local root CA out of the container; returns the path or '' in acme mode.
    param([string]$Path = '')
    if ((Get-HvEnvValue 'HV_TLS_MODE' 'internal') -ne 'internal') { return '' }
    if (-not $Path) { $Path = Join-HvPath (New-HvDirectory (Get-HvPath 'state')) 'homevault-root-ca.crt' }
    [void](New-HvDirectory ([System.IO.Path]::GetDirectoryName($Path)))
    $r = Invoke-HvCompose -Arguments @('cp', ('caddy:' + $script:HvCaPathInContainer), $Path) -Capture -AllowFailure
    if ($r.ExitCode -ne 0 -or -not [System.IO.File]::Exists($Path)) { return '' }
    return $Path
}

function Show-HvCaInstructions {
    param([string]$Path)
    $fp = Get-HvCertFingerprint $Path
    Write-HvOk ('根证书已导出：' + $Path)
    Write-HvInfo ('名称：' + $fp.Subject + '；有效期至 ' + $fp.NotAfter.ToString('yyyy-MM-dd'))
    Write-HvInfo ('SHA-256 指纹：' + $fp.Fingerprint)
    Write-HvInfo '安装方法（安装后请核对上面的指纹）：'
    Write-HvInfo '  安卓：把 .crt 文件传到手机 → 设置里搜索“证书” → 安装证书 → CA 证书 → 仍然安装 → 选择该文件。'
    Write-HvInfo '  iPhone/iPad：用 AirDrop/邮件发送 → 设置 → 已下载描述文件 → 安装 → 通用 → 关于本机 → 证书信任设置 → 打开完全信任。'
    Write-HvInfo ('  Windows 电脑（管理员 PowerShell）：certutil -addstore -f ROOT "' + $Path + '"')
    Write-HvInfo '  macOS：sudo security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain homevault-root-ca.crt'
    Write-HvInfo '  Linux：sudo cp homevault-root-ca.crt /usr/local/share/ca-certificates/ && sudo update-ca-certificates'
    Write-HvInfo '注意：服务器发送 HSTS，电脑版 Nextcloud 客户端必须在系统中信任此证书，无法“临时信任”。'
}

function Install-HvCaLocal {
    param([string]$Path)
    if (-not (Test-HvWindows)) { return }
    if (-not (Test-HvAdmin)) { Write-HvInfo '（以管理员身份运行可自动把根证书安装到本机“受信任的根证书颁发机构”）'; return }
    if (Read-HvYesNo '是否把 HomeVault 根证书安装到本机（让这台电脑的浏览器/Nextcloud 客户端信任它）？' $true) {
        [void](Invoke-HvNative -FilePath 'certutil.exe' -ArgumentList @('-addstore', '-f', 'ROOT', $Path) -Capture)
        Write-HvOk '已安装到本机受信任的根证书。'
    }
}

function Invoke-HvCmdCa {
    param([object[]]$Arguments = @())
    $p = Read-HvCommandArgs -Arguments $Arguments -Options @('export') -Switches @('install')
    [void](Get-HvEnv)
    if ((Get-HvEnvValue 'HV_TLS_MODE' 'internal') -ne 'internal') {
        Write-HvInfo '当前为域名证书模式（acme-dns），证书由公共 CA 签发，客户端无需安装根证书。'
        return
    }
    $path = Export-HvCa -Path (Get-HvOpt $p 'export' '')
    if (-not $path) { Stop-Hv '导出失败：caddy 容器是否在运行？（.\windows\hv.ps1 status）' }
    Show-HvCaInstructions $path
    if (Test-HvOpt $p 'install') { Install-HvCaLocal $path }
}
