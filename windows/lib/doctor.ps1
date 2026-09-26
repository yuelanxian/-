# HomeVault Windows CLI - doctor: health and security checks with ✔ / ! / ✘ output.

function Get-HvPublisherIssues {
    # Pure: check published ports from `docker compose ps --format json` rows.
    # Only caddy may publish TCP; everything must be bound to IPv4 (the configured bind IP).
    param([object[]]$Rows = @(), [string]$BindIp = '0.0.0.0', [string[]]$AllowedTcpPorts = @())
    $issues = @()
    foreach ($r in @($Rows)) {
        $svc = [string](Get-HvPropValue $r 'Service')
        foreach ($pub in @(Get-HvPropValue $r 'Publishers' @())) {
            if ($null -eq $pub) { continue }
            $pp = [int](Get-HvPropValue $pub 'PublishedPort' 0)
            if ($pp -eq 0) { continue }
            $url = [string](Get-HvPropValue $pub 'URL' '')
            $proto = [string](Get-HvPropValue $pub 'Protocol' 'tcp')
            if ($url -match ':' -or $url -eq '::') { $issues += ($svc + ' 的端口 ' + $pp + '/' + $proto + ' 发布在 IPv6 地址 [' + $url + '] 上') ; continue }
            if ($proto -eq 'tcp' -and $svc -ne 'caddy') { $issues += ($svc + ' 不应发布 TCP 端口 ' + $pp) ; continue }
            if ($proto -eq 'tcp' -and $AllowedTcpPorts.Count -gt 0 -and $AllowedTcpPorts -notcontains [string]$pp) { $issues += ($svc + ' 发布了未预期的端口 ' + $pp) }
            if ($url -and $BindIp -and $url -ne $BindIp) { $issues += ($svc + ' 的端口 ' + $pp + ' 绑定在 ' + $url + '（配置为 ' + $BindIp + '）') }
        }
    }
    return $issues
}

function Get-HvSetupChecksSummary {
    # Pure: count error/warning entries of `occ setupchecks --output=json`.
    param($Json)
    $res = [pscustomobject]@{ Errors = 0; Warnings = 0; ErrorNames = @(); WarningNames = @() }
    if ($null -eq $Json) { return $res }
    foreach ($cat in $Json.PSObject.Properties) {
        $checks = $cat.Value
        if ($null -eq $checks) { continue }
        foreach ($c in $checks.PSObject.Properties) {
            $sev = [string](Get-HvPropValue $c.Value 'severity' '')
            $nm = [string](Get-HvPropValue $c.Value 'name' $c.Name)
            if ($sev -eq 'error') { $res.Errors++; $res.ErrorNames += $nm }
            elseif ($sev -eq 'warning') { $res.Warnings++; $res.WarningNames += $nm }
        }
    }
    return $res
}

function Invoke-HvDoctor {
    $script:HvDocFail = 0
    $script:HvDocWarn = 0
    $ok = { param($m) Write-HvOk $m }
    $warn = { param($m) $script:HvDocWarn++; Write-HvWarn $m }
    $fail = { param($m) $script:HvDocFail++; Write-HvErr $m }

    if (-not (Test-HvAdmin)) { Write-HvInfo '提示：以管理员身份运行可检查全部项目（计划任务、WireGuard 握手等）。' }
    Write-HvStep 'Docker'
    $info = Get-HvDockerInfo
    if (-not $info.Ok) { & $fail ('Docker 引擎不可用：' + $info.Error); Write-HvErr '后续检查需要 Docker，已停止。'; return 1 }
    & $ok ('Docker 引擎 ' + $info.ServerVersion + '（' + $info.Platform + '），Compose ' + $info.ComposeVersion)
    if ($info.DesktopVersion -and (Compare-HvVersion $info.DesktopVersion '4.92.0') -lt 0) { & $warn ('Docker Desktop ' + $info.DesktopVersion + ' 低于 4.92（迁移磁盘镜像到其他盘有已知问题）') }
    $envv = Get-HvEnv

    Write-HvStep '容器'
    $rows = @(Get-HvComposePs)
    foreach ($svc in @('caddy', 'app', 'cron', 'db', 'redis', 'panel', 'socket-proxy')) {
        $s = Get-HvServiceState -Rows $rows -Service $svc
        if ($null -eq $s) { & $fail ($svc + '：未创建'); continue }
        if ($s.State -ne 'running') { & $fail ($svc + '：' + $s.State) }
        elseif ($s.Health -and $s.Health -ne 'healthy') { & $fail ($svc + '：运行中但健康检查为 ' + $s.Health) }
        else { & $ok ($svc + '：' + $s.Status) }
    }
    if (Test-HvTrue (Get-HvEnvDictValue $envv 'HV_DDNS_ENABLED' 'false')) {
        $s = Get-HvServiceState -Rows $rows -Service 'ddns-go'
        if ($s -and $s.State -eq 'running') { & $ok 'ddns-go：运行中' } else { & $warn 'ddns-go：未运行' }
    }
    $issues = @(Get-HvPublisherIssues -Rows $rows -BindIp (Get-HvEnvDictValue $envv 'HV_BIND_IP' '0.0.0.0') `
            -AllowedTcpPorts @((Get-HvEnvDictValue $envv 'HV_HTTP_PORT' '80'), (Get-HvEnvDictValue $envv 'HV_HTTPS_PORT' '443'), (Get-HvEnvDictValue $envv 'HV_ADMIN_PORT' '8443'), (Get-HvEnvDictValue $envv 'HV_PANEL_PORT' '9443')))
    if ($issues.Count -eq 0) { & $ok '端口发布：仅 caddy，且只绑定 IPv4' } else { foreach ($i in $issues) { & $fail ('端口发布：' + $i) } }

    Write-HvStep 'Nextcloud'
    $appUp = Test-HvAppRunning
    if ($appUp) {
        $st = Get-HvOccStatus
        if ($null -eq $st) { & $fail 'occ status 失败' }
        else {
            if (Test-HvTrue (Get-HvPropValue $st 'installed')) { & $ok ('已安装，版本 ' + [string](Get-HvPropValue $st 'versionstring')) } else { & $fail '尚未完成安装' }
            if (Test-HvTrue (Get-HvPropValue $st 'maintenance')) { & $fail '处于维护模式（occ maintenance:mode --off）' }
            if (Test-HvTrue (Get-HvPropValue $st 'needsDbUpgrade')) { & $fail '需要数据库升级' }
        }
        $v = Get-HvOccValue @('config:system:get', 'twofactor_enforced')
        if ($v -eq 'true') { & $ok '已强制两步验证' } else { & $fail '未强制两步验证（运行 harden）' }
        $v = Get-HvOccValue @('config:system:get', 'token_auth_enforced')
        if ($v -eq 'true') { & $ok '已强制应用密码（token_auth_enforced）' } else { & $fail 'token_auth_enforced 未开启（运行 harden）' }
        $v = Get-HvOccValue @('config:app:get', 'core', 'shareapi_allow_links')
        $want = 'no'; if (Test-HvTrue (Get-HvEnvDictValue $envv 'HV_ALLOW_PUBLIC_LINKS' 'false')) { $want = 'yes' }
        if ($v -eq $want) { & $ok ('公开分享链接：' + $v) } else { & $warn ('公开分享链接：' + $v + '（期望 ' + $want + '）') }
        $sc = Get-HvSetupChecksSummary (Get-HvOccJson @('setupchecks', '--output=json'))
        if ($sc.Errors -gt 0) { & $fail ('setupchecks：' + $sc.Errors + ' 个错误（' + ($sc.ErrorNames -join '、') + '）') }
        elseif ($sc.Warnings -gt 0) { & $warn ('setupchecks：' + $sc.Warnings + ' 个警告（' + ($sc.WarningNames -join '、') + '）') }
        else { & $ok 'setupchecks：无错误和警告' }
    } else { & $fail 'app 未运行，跳过 Nextcloud 检查' }

    Write-HvStep 'HTTPS / 证书'
    $lan = Get-HvEnvDictValue $envv 'HV_LAN_IP'
    $port = [int](Get-HvEnvDictValue $envv 'HV_HTTPS_PORT' '443')
    $hostName = Get-HvEnvDictValue $envv 'HV_HOST' $lan
    $probeIp = '127.0.0.1'
    $bind = Get-HvEnvDictValue $envv 'HV_BIND_IP' '0.0.0.0'
    if ($bind -ne '0.0.0.0') { $probeIp = $bind }
    $probe = Invoke-HvHttpsProbe -Ip $probeIp -Port $port -SniHost $hostName
    if ($probe.Ok -and $probe.Body -match '"installed"\s*:\s*true') { & $ok ('https://' + $hostName + ':' + $port + '/status.php 正常') }
    elseif ($probe.Error) { & $fail ('HTTPS 探测失败：' + $probe.Error) }
    else { & $fail ('HTTPS 返回：' + $probe.StatusLine) }
    if ($probe.Certificate) {
        $days = [int]($probe.Certificate.NotAfter - (Get-Date)).TotalDays
        if ($days -lt 0) { & $fail ('TLS 证书已过期（' + $probe.Certificate.NotAfter.ToString('yyyy-MM-dd') + '）') }
        elseif ($days -lt 7) { & $warn ('TLS 证书 ' + $days + ' 天后过期（Caddy 应自动续期）') }
        else { & $ok ('TLS 证书有效期还剩 ' + $days + ' 天（' + $probe.Certificate.Issuer + '）') }
    }

    $panelPort = [int](Get-HvEnvDictValue $envv 'HV_PANEL_PORT' '9443')
    $pp = Invoke-HvHttpsProbe -Ip $probeIp -Port $panelPort -SniHost $hostName -Path '/healthz'
    if ($pp.Ok) { & $ok ('管理面板 https://' + $hostName + ':' + $panelPort + ' 正常') }
    elseif ($pp.Error) { & $fail ('管理面板探测失败：' + $pp.Error) }
    else { & $fail ('管理面板返回：' + $pp.StatusLine) }

    Write-HvStep '网络 / 防火墙 / VPN'
    $ips = @(Get-HvLocalIPv4s)
    if ($lan -and $ips -contains $lan) { & $ok ('局域网 IP 未变化：' + $lan) } else { & $fail ('本机已没有 IP ' + $lan + '：请在路由器上为本机设置固定 IP（DHCP 静态分配），或重新运行 install') }
    $fwNames = @(Get-HvHomeVaultFirewallRules | Where-Object { [string]$_.Enabled -eq 'True' } | ForEach-Object { $_.Name })
    foreach ($spec in @(Get-HvFirewallRuleSpecs -Env $envv)) {
        if ($fwNames -notcontains $spec.Name) { & $fail ('缺少防火墙规则 ' + $spec.Name + '（管理员运行 firewall --apply）'); continue }
        $have = @()
        try { $have = @((Get-NetFirewallRule -Name $spec.Name -ErrorAction Stop | Get-NetFirewallPortFilter).LocalPort | ForEach-Object { [string]$_ }) } catch { }
        $missing = @(@($spec.LocalPort) | Where-Object { $have -notcontains [string]$_ })
        if ($have.Count -gt 0 -and $missing.Count -gt 0) { & $fail ('防火墙规则 ' + $spec.Name + ' 未包含端口 ' + ($missing -join ',') + '（管理员运行 firewall --apply 更新）') }
        else { & $ok ('防火墙规则 ' + $spec.Name) }
    }
    $docker = @(Get-HvDockerFirewallRules)
    if ($docker.Count -gt 0 -and $fwNames -notcontains 'HomeVault-Block-Other') { & $warn ('Docker Desktop 有 ' + $docker.Count + ' 条放行规则，且缺少 HomeVault 阻止规则') }
    if (Test-HvTrue (Get-HvEnvDictValue $envv 'HV_VPN_ENABLED' 'true')) {
        $svc = Get-HvTunnelService
        if ($svc -and [string]$svc.Status -eq 'Running') { & $ok 'WireGuard 隧道服务运行中' } else { & $fail 'WireGuard 隧道服务未运行（管理员运行 vpn init）' }
        if ($svc -and [string]$svc.StartType -ne 'Automatic') { & $warn ('隧道服务启动类型为 ' + [string]$svc.StartType) }
        if (Test-HvWeakHost) { & $ok 'Weak Host 已在隧道网卡上开启' } else { & $fail 'Weak Host 未开启（VPN 客户端无法访问局域网 IP）' }
        if (Get-ScheduledTask -TaskName $script:HvWeakHostTask -ErrorAction SilentlyContinue) { & $ok ('计划任务 ' + $script:HvWeakHostTask) } else { & $warn ('缺少计划任务 ' + $script:HvWeakHostTask) }
        if (Get-ScheduledTask -TaskName 'HomeVault-VpnStatus' -ErrorAction SilentlyContinue) { & $ok '计划任务 HomeVault-VpnStatus（管理面板 VPN 页）' } else { & $warn '缺少计划任务 HomeVault-VpnStatus（管理面板看不到 VPN 设备在线状态；重新运行 install）' }
    }

    Write-HvStep '磁盘空间'
    $paths = @()
    foreach ($k in @('HV_NC_DATA_PATH', 'HV_DUMP_DIR', 'HV_BACKUP_LOCAL_PATH')) { $v = Get-HvEnvDictValue $envv $k; if ($v) { $paths += $v } }
    foreach ($r in @(Get-HvStorageRows)) { $paths += $r.Path }
    $paths += (Get-HvRoot)
    $seen = @{}
    foreach ($pth in $paths) {
        $letter = Get-HvDriveLetterFromPath $pth
        if (-not $letter -or $seen.ContainsKey($letter)) { continue }
        $seen[$letter] = $true
        try {
            $di = New-Object System.IO.DriveInfo($letter)
            if (-not $di.IsReady) { & $fail ($letter + ': 不可用（外置硬盘未连接？）'); continue }
            $pct = [Math]::Round(100.0 * $di.AvailableFreeSpace / $di.TotalSize, 1)
            $msg = $letter + ': 可用 ' + (ConvertTo-HvSizeText $di.AvailableFreeSpace) + ' / ' + (ConvertTo-HvSizeText $di.TotalSize) + '（' + $pct + '%）'
            if ($pct -lt 10) { & $warn ($msg + '，空间不足 10%') } else { & $ok $msg }
        } catch { & $warn ($letter + ': 无法读取空间信息') }
    }

    Write-HvStep '备份'
    $t = Get-HvEnvDictValue $envv 'HV_BACKUP_TARGET'
    if ($t -ne 'local' -and $t -ne 's3') { & $warn '未配置备份（HV_BACKUP_TARGET）' }
    else {
        $f = Get-HvPath (Join-HvPath 'state' 'last-backup-ok')
        $bsf = Get-HvPath (Join-HvPath 'state' 'backup-status.json')
        if ([System.IO.File]::Exists($bsf)) {
            try {
                $bs = ConvertFrom-Json -InputObject (Read-HvTextFile $bsf)
                $bst = [string](Get-HvPropValue $bs 'state' '')
                if ($bst -eq 'failed' -or $bst -eq 'partial') { & $fail ('最近一次备份' + @{ failed = '失败'; partial = '不完整' }[$bst] + '：' + [string](Get-HvPropValue $bs 'message' '') + '（日志 ' + [string](Get-HvPropValue $bs 'log_file' '') + '）') }
            } catch { }
        }
        $age = $null
        if ([System.IO.File]::Exists($f)) { $age = Get-HvBackupAgeHours -IsoText (Read-HvTextFile $f) -Now (Get-Date) }
        if ($null -eq $age) { & $fail '还没有成功的备份（运行 backup --init）' }
        elseif ($age -gt 48) { & $fail ('最近一次成功备份在 ' + [int]$age + ' 小时前（超过 48 小时）') }
        else { & $ok ('最近一次成功备份在 ' + [int]$age + ' 小时前') }
        if (Get-ScheduledTask -TaskName $script:HvBackupTask -ErrorAction SilentlyContinue) { & $ok ('计划任务 ' + $script:HvBackupTask) } else { & $warn ('缺少计划任务 ' + $script:HvBackupTask + '（运行 schedule-backup）') }
    }

    Write-HvStep '权限'
    if (Test-HvPrivateAcl (Get-HvSecretsDir)) { & $ok 'secrets\ 仅限 SYSTEM / 管理员 / 当前用户' } else { & $fail 'secrets\ 权限过宽（重新运行 install 修复）' }
    if (Test-HvPrivateAcl (Get-HvEnvPath)) { & $ok '.env 权限已收紧' } else { & $warn '.env 权限较宽' }

    Write-HvStep '日志与维护任务'
    $ld = Get-HvEnvLogDir
    if ($ld -and [System.IO.Directory]::Exists($ld)) { & $ok ('日志目录 ' + $ld + '（保留 ' + (Get-HvEnvDictValue $envv 'HV_LOG_RETENTION_DAYS' '7') + ' 天）') }
    else { & $fail ('日志目录不存在：' + $ld + '（运行 up 或 install 创建）') }
    foreach ($tn in @('HomeVault-Maintenance', 'HomeVault-Requests')) {
        if (Get-ScheduledTask -TaskName $tn -ErrorAction SilentlyContinue) { & $ok ('计划任务 ' + $tn) } else { & $warn ('缺少计划任务 ' + $tn + '（重新运行 install 创建）') }
    }
    $sf = Get-HvPath (Join-HvPath 'state' 'status.json')
    if ([System.IO.File]::Exists($sf)) {
        $ageH = ((Get-Date) - [System.IO.File]::GetLastWriteTime($sf)).TotalHours
        if ($ageH -gt 36) { & $warn ('state\status.json 已 ' + [int]$ageH + ' 小时未更新（每日维护任务可能未运行）') } else { & $ok '每日维护状态已更新' }
    } else { & $warn '还没有 state\status.json（每日维护任务尚未运行过）' }

    Write-HvStep '开机自启（无人值守）'
    $a = Get-HvAutostartState
    if ($a.DockerAutostart) { & $ok 'Docker Desktop 登录后自动启动' } else { & $warn 'Docker Desktop 未设置登录后自动启动（Settings → General → Start Docker Desktop when you sign in）' }
    if ($a.Autologon) { & $ok ('自动登录已配置（' + $a.AutologonUser + '）') } else { & $warn '未配置自动登录：停电/重启后需要有人登录，Docker 才会启动（运行 autostart）' }
    if ($a.LockTask) { & $ok '登录后自动锁屏任务 HomeVault-Lock' } elseif ($a.Autologon) { & $warn '已自动登录但没有锁屏任务 HomeVault-Lock' }

    Write-Host ''
    if ($script:HvDocFail -gt 0) { Write-HvErr ('检查完成：' + $script:HvDocFail + ' 项失败，' + $script:HvDocWarn + ' 项警告。'); return 1 }
    Write-HvOk ('检查完成：全部通过（' + $script:HvDocWarn + ' 项警告）。')
    return 0
}

function Invoke-HvCmdDoctor {
    param([object[]]$Arguments = @())
    [void](Read-HvCommandArgs -Arguments $Arguments)
    Assert-HvWindows 'doctor'
    [void](Get-HvEnv)
    $rc = @(Invoke-HvDoctor)
    $code = [int]$rc[$rc.Count - 1]
    if ($code -ne 0) { $script:HvExitCode = $code }
}
