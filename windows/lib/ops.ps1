# HomeVault Windows CLI - lifecycle wrappers: up / down / restart / status / logs / pull / update.

function Get-HvNextMajorImage {
    # Pure: ".../nextcloud:34-apache" -> ".../nextcloud:35-apache" (exactly one major).
    param([string]$Image)
    $m = [regex]::Match($Image, '^(?<repo>.+):(?<major>\d+)(?<rest>(\.\d+)*(-[A-Za-z0-9.-]+)?)$')
    if (-not $m.Success) { throw ('无法识别 NEXTCLOUD_IMAGE 的版本号：' + $Image) }
    $next = [int]$m.Groups['major'].Value + 1
    $rest = $m.Groups['rest'].Value -replace '^(\.\d+)+', ''
    return ($m.Groups['repo'].Value + ':' + $next + $rest)
}

function Get-HvImageMajor {
    param([string]$Image)
    $m = [regex]::Match($Image, ':(\d+)')
    if ($m.Success) { return [int]$m.Groups[1].Value }
    return 0
}

function Get-HvCanonicalUrl {
    $h = Get-HvEnvValue 'HV_HOST' (Get-HvEnvValue 'HV_LAN_IP')
    $p = Get-HvEnvValue 'HV_HTTPS_PORT' '443'
    if ($p -eq '443') { return ('https://' + $h) }
    return ('https://' + $h + ':' + $p)
}

function Get-HvPanelUrl {
    # Management panel: https://HV_HOST:HV_PANEL_PORT (SPEC section 15).
    $h = Get-HvEnvValue 'HV_HOST' (Get-HvEnvValue 'HV_LAN_IP')
    return ('https://' + $h + ':' + (Get-HvEnvValue 'HV_PANEL_PORT' '9443'))
}

function Test-HvPanelImage {
    $img = Get-HvEnvValue 'PANEL_IMAGE' 'homevault/panel:1.0.0'
    $r = Invoke-HvNative -FilePath 'docker' -ArgumentList @('image', 'inspect', '--format', '{{.Id}}', $img) -Capture -AllowFailure
    return ($r.ExitCode -eq 0)
}

function Invoke-HvPanelBuild {
    # The panel image is always built locally from panel/ (never pulled; see compose.yaml).
    param([switch]$IfMissing)
    if (-not [System.IO.File]::Exists((Join-HvPath (Get-HvPath 'panel') 'Dockerfile'))) {
        Write-HvWarn '缺少 panel\Dockerfile（仓库不完整？），跳过管理面板镜像构建。'
        return
    }
    if ($IfMissing -and (Test-HvPanelImage)) { return }
    Write-HvStep '构建管理面板镜像（本机构建，首次约需 1-3 分钟）...'
    [void](Invoke-HvCompose -Arguments @('build', 'panel'))
}

function Invoke-HvUp {
    Update-HvDerivedEnv
    Initialize-HvRuntimeDirs
    [void](Write-HvComposeStorageFile)
    Invoke-HvPanelBuild -IfMissing
    Write-HvStep '启动 HomeVault ...'
    [void](Invoke-HvCompose -Arguments @('up', '-d', '--remove-orphans'))
    Write-HvOk ('已启动：' + (Get-HvCanonicalUrl) + '；管理面板：' + (Get-HvPanelUrl))
}

function Invoke-HvCmdUp {
    param([object[]]$Arguments = @())
    $p = Read-HvCommandArgs -Arguments $Arguments -Switches @('wait')
    Assert-HvDockerQuick
    Invoke-HvUp
    if (Test-HvOpt $p 'wait') { [void](Wait-HvHealthy -TimeoutSec 900) }
}

function Assert-HvDockerQuick {
    [void](Get-HvEnv)
    if (-not (Get-Command docker -ErrorAction SilentlyContinue)) { Stop-Hv '未找到 docker 命令：请安装并启动 Docker Desktop。' }
}

function Invoke-HvCmdDown {
    param([object[]]$Arguments = @())
    [void](Read-HvCommandArgs -Arguments $Arguments)
    Assert-HvDockerQuick
    [void](Invoke-HvCompose -Arguments @('down'))
    Write-HvOk '已停止（数据卷保留）。'
}

function Invoke-HvCmdRestart {
    param([object[]]$Arguments = @())
    $p = Read-HvCommandArgs -Arguments $Arguments
    Assert-HvDockerQuick
    [void](Invoke-HvCompose -Arguments (@('restart') + @($p.Positional)))
}

function Invoke-HvCmdStatus {
    param([object[]]$Arguments = @())
    [void](Read-HvCommandArgs -Arguments $Arguments)
    Assert-HvDockerQuick
    [void](Invoke-HvCompose -Arguments @('ps', '-a'))
    Write-Host ''
    Write-HvInfo ('访问地址：' + (Get-HvCanonicalUrl))
    Write-HvInfo ('管理面板：' + (Get-HvPanelUrl))
    $ld = Get-HvEnvLogDir
    if ($ld) { Write-HvInfo ('日志目录：' + $ld + '（保留 ' + (Get-HvEnvValue 'HV_LOG_RETENTION_DAYS' '7') + ' 天）') }
    if ((Test-HvWindows) -and (Test-HvTrue (Get-HvEnvValue 'HV_VPN_ENABLED' 'true'))) {
        $svc = Get-HvTunnelService
        if ($svc) { Write-HvInfo ('WireGuard 隧道服务：' + [string]$svc.Status) } else { Write-HvInfo 'WireGuard 隧道服务：未安装' }
    }
    $f = Get-HvPath (Join-HvPath 'state' 'last-backup-ok')
    if ([System.IO.File]::Exists($f)) { Write-HvInfo ('最近一次成功备份：' + (Read-HvTextFile $f).Trim()) } else { Write-HvInfo '最近一次成功备份：无' }
    $bs = Get-HvPath (Join-HvPath 'state' 'backup-status.json')
    if ([System.IO.File]::Exists($bs)) {
        try {
            $j = ConvertFrom-Json -InputObject (Read-HvTextFile $bs)
            $stText = @{ ok = '成功'; failed = '失败'; partial = '不完整'; running = '进行中'; never = '从未' }
            $st = [string](Get-HvPropValue $j 'state' '')
            $label = $st
            if ($stText.ContainsKey($st)) { $label = $stText[$st] }
            Write-HvInfo ('最近一次备份：' + $label + '（' + [string](Get-HvPropValue $j 'last_run' '') + '）' + [string](Get-HvPropValue $j 'message' ''))
        } catch { }
    }
}

function Invoke-HvCmdLogs {
    param([object[]]$Arguments = @())
    $p = Read-HvCommandArgs -Arguments $Arguments -Switches @('follow', 'f') -Options @('tail')
    Assert-HvDockerQuick
    $a = @('logs', '--tail', (Get-HvOpt $p 'tail' '200'))
    if ((Test-HvOpt $p 'follow') -or (Test-HvOpt $p 'f')) { $a += '-f' }
    $a += @($p.Positional)
    [void](Invoke-HvCompose -Arguments $a -AllowFailure)
}

function Invoke-HvCmdPull {
    param([object[]]$Arguments = @())
    [void](Read-HvCommandArgs -Arguments $Arguments)
    Assert-HvDockerQuick
    Update-HvDerivedEnv
    [void](Invoke-HvCompose -Arguments @('pull', '--ignore-buildable'))
    if ((Get-HvEnvValue 'HV_TLS_MODE' 'internal') -eq 'acme-dns') { [void](Invoke-HvCompose -Arguments @('build', '--pull', 'caddy')) }
    Write-HvOk '镜像已更新；运行 up 使新镜像生效。'
}

function Invoke-HvCmdUpdate {
    param([object[]]$Arguments = @())
    $p = Read-HvCommandArgs -Arguments $Arguments -Switches @('major', 'skip-backup')
    [void](Assert-HvDocker)
    $envv = Get-HvEnv
    if (Test-HvOpt $p 'major') {
        $img = Get-HvEnvDictValue $envv 'NEXTCLOUD_IMAGE'
        $next = Get-HvNextMajorImage $img
        $st = Get-HvOccStatus
        if ($st) {
            $installedMajor = [int](([string](Get-HvPropValue $st 'versionstring' '0')) -split '\.')[0]
            if ($installedMajor -ne (Get-HvImageMajor $img)) { Stop-Hv ('当前运行的 Nextcloud 为 ' + $installedMajor + '，与镜像 ' + $img + ' 不一致：请先完成上一次升级（运行 update）。') }
        }
        Write-HvWarn ('大版本升级：' + $img + ' → ' + $next + '（Nextcloud 只能逐个大版本升级；请先确认所用应用已支持新版本）')
        if (-not (Read-HvYesNo '继续？' $false)) { Stop-Hv '已取消。' }
        Update-HvEnv ([ordered]@{ NEXTCLOUD_IMAGE = $next })
    }
    if (-not (Test-HvOpt $p 'skip-backup')) {
        $t = Get-HvEnvValue 'HV_BACKUP_TARGET'
        if ($t -eq 'local' -or $t -eq 's3') { Invoke-HvBackup }
        elseif (-not (Read-HvYesNo '未配置备份，升级前无法自动备份。仍然继续？' $false)) { Stop-Hv '已取消。' }
    }
    Update-HvDerivedEnv
    Initialize-HvRuntimeDirs
    [void](Write-HvComposeStorageFile)
    Write-HvStep '拉取新镜像 ...'
    [void](Invoke-HvCompose -Arguments @('pull', '--ignore-buildable'))
    if ((Get-HvEnvValue 'HV_TLS_MODE' 'internal') -eq 'acme-dns') { [void](Invoke-HvCompose -Arguments @('build', '--pull', 'caddy')) }
    Invoke-HvPanelBuild
    Write-HvStep '重建容器（Nextcloud 会在启动时自动执行 occ upgrade）...'
    [void](Invoke-HvCompose -Arguments @('up', '-d', '--remove-orphans'))
    [void](Wait-HvHealthy -TimeoutSec 1800)
    [void](Invoke-HvOcc -OccArgs @('db:add-missing-indices') -AllowFailure)
    Write-HvOk '更新完成。建议运行 .\windows\hv.ps1 doctor 检查。'
}
