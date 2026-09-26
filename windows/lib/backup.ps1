# HomeVault Windows CLI - restic backup / restore (via `docker compose run --rm backup ...`) and Task Scheduler.

$script:HvBackupTask = 'HomeVault-Backup'

# ---------------------------------------------------------------- pure argument builders

function Get-HvResticRepoArgs {
    param([System.Collections.IDictionary]$Env)
    $t = Get-HvEnvDictValue $Env 'HV_BACKUP_TARGET' ''
    if ($t -eq 'local') { return @('-r', '/repo') }
    if ($t -eq 's3') {
        $repo = Get-HvEnvDictValue $Env 'HV_BACKUP_S3_REPO'
        if (-not $repo) { throw '缺少 HV_BACKUP_S3_REPO。' }
        $a = @('-r', $repo)
        foreach ($x in ((Get-HvEnvDictValue $Env 'HV_BACKUP_S3_OPTIONS') -split '\s+')) { if ($x) { $a += $x } }
        return $a
    }
    throw '未配置备份目标（HV_BACKUP_TARGET 应为 local 或 s3）。'
}

function Get-HvBackupPaths {
    # Paths inside the backup container (SPEC section 10). Only existing sources are listed (missing path = restic exit 3).
    param([object[]]$Storages = @(), [bool]$WinWireGuard = $false, [bool]$WgEasy = $false)
    $p = @('/src/nextcloud-html/config', '/src/nextcloud-html/custom_apps', '/src/nextcloud-html/themes',
        '/src/nextcloud-data', '/src/caddy-data', '/src/dumps', '/src/project')
    if ($WgEasy) { $p += '/src/wg-easy' }
    if ($WinWireGuard) { $p += '/src/windows-wireguard' }
    foreach ($s in @($Storages)) { if ($s.Backup) { $p += ('/src/storage/' + $s.Slug) } }
    return $p
}

function Get-HvResticBackupArgs {
    param([System.Collections.IDictionary]$Env, [string[]]$Paths)
    $a = @(Get-HvResticRepoArgs $Env) + @('backup') + @($Paths) + @('--tag', 'homevault', '--host', 'homevault',
        '--exclude', '/src/nextcloud-data/appdata_*/preview',
        '--exclude', '/src/nextcloud-data/*.log',
        '--exclude', '/src/project/.git',
        '--exclude', '/src/project/restore')
    return $a
}

function Get-HvResticForgetArgs {
    param([System.Collections.IDictionary]$Env)
    return (@(Get-HvResticRepoArgs $Env) + @('forget', '--tag', 'homevault', '--group-by', 'host,tags',
            '--keep-daily', (Get-HvEnvDictValue $Env 'HV_BACKUP_KEEP_DAILY' '7'),
            '--keep-weekly', (Get-HvEnvDictValue $Env 'HV_BACKUP_KEEP_WEEKLY' '4'),
            '--keep-monthly', (Get-HvEnvDictValue $Env 'HV_BACKUP_KEEP_MONTHLY' '12'),
            '--prune'))
}

function Get-HvResticCheckArgs {
    param([System.Collections.IDictionary]$Env)
    return (@(Get-HvResticRepoArgs $Env) + @('check', '--read-data-subset=5%'))
}

function ConvertTo-HvTaskTime {
    # "HH:MM" -> DateTime today at that time (throws on invalid input).
    param([string]$Text)
    if ($Text -notmatch '^\s*(\d{1,2}):(\d{2})\s*$') { throw ('时间格式应为 HH:MM：' + $Text) }
    $h = [int]$Matches[1]; $m = [int]$Matches[2]
    if ($h -gt 23 -or $m -gt 59) { throw ('无效时间：' + $Text) }
    return (Get-Date -Hour $h -Minute $m -Second 0 -Millisecond 0)
}

function Get-HvBackupAgeHours {
    param([AllowEmptyString()][string]$IsoText, [datetime]$Now)
    if (-not $IsoText) { return $null }
    $dt = [datetime]::MinValue
    if (-not [datetime]::TryParse($IsoText.Trim(), [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::RoundtripKind, [ref]$dt)) { return $null }
    return (($Now.ToUniversalTime() - $dt.ToUniversalTime()).TotalHours)
}

# ---------------------------------------------------------------- runtime helpers

function Invoke-HvRestic {
    param([string[]]$ResticArgs, [switch]$Capture, [switch]$Tee, [switch]$AllowFailure, [string[]]$RunArgs = @(), [string[]]$ExtraFiles = @(), [switch]$Quiet)
    $a = @('run', '--rm', '-T') + @($RunArgs) + @('backup') + @($ResticArgs)
    return (Invoke-HvCompose -Arguments $a -Tools -Capture:$Capture -Tee:$Tee -AllowFailure:$AllowFailure -ExtraFiles $ExtraFiles -Quiet:$Quiet)
}

function Assert-HvBackupConfigured {
    $envv = Get-HvEnv
    $t = Get-HvEnvDictValue $envv 'HV_BACKUP_TARGET'
    if ($t -ne 'local' -and $t -ne 's3') { Stop-Hv '未配置备份目标：请在 .env 中设置 HV_BACKUP_TARGET=local（并设置 HV_BACKUP_LOCAL_PATH）或 s3，或重新运行 install。' }
    if ($t -eq 'local') {
        $lp = Get-HvEnvDictValue $envv 'HV_BACKUP_LOCAL_PATH'
        if (-not $lp) { Stop-Hv '缺少 HV_BACKUP_LOCAL_PATH。' }
        if ((Test-HvWindows) -and -not [System.IO.Directory]::Exists($lp)) {
            Stop-Hv ('备份目录不可用：' + $lp + '（移动硬盘是否已连接？盘符是否变化？）')
        }
    }
    if (-not (Test-HvSecret 'restic_password')) { Stop-Hv '缺少 secrets\restic_password。' }
    return $envv
}

function Test-HvResticRepo {
    # 0 = ok, 10 = not initialised, 12 = wrong password, other = error.
    param([System.Collections.IDictionary]$Env)
    $r = Invoke-HvRestic -ResticArgs (@(Get-HvResticRepoArgs $Env) + @('cat', 'config')) -Capture -AllowFailure
    return $r.ExitCode
}

function Initialize-HvResticRepo {
    param([System.Collections.IDictionary]$Env, [bool]$AllowInit)
    $code = Test-HvResticRepo $Env
    if ($code -eq 0) { return }
    if ($code -eq 12) { Stop-Hv 'restic 仓库密码错误：secrets\restic_password 与仓库不匹配。' 12 }
    if ($code -eq 10) {
        if (-not $AllowInit) { Stop-Hv '备份仓库尚未初始化：请运行 .\windows\hv.ps1 backup --init' 10 }
        Write-HvStep '初始化 restic 备份仓库...'
        [void](Invoke-HvRestic -ResticArgs (@(Get-HvResticRepoArgs $Env) + @('init')) -Tee)
        Write-HvOk 'restic 仓库已初始化。请把 secrets\restic_password 中的密码离线保存（丢失后备份无法恢复）。'
        return
    }
    Stop-Hv ('无法访问备份仓库（restic 退出码 ' + $code + '）。') $code
}

function Invoke-HvDbDump {
    # pg_dump (plain SQL) into HV_DUMP_DIR\nextcloud.sql via a temp file.
    param([System.Collections.IDictionary]$Env)
    $dir = Get-HvEnvDictValue $Env 'HV_DUMP_DIR'
    if (-not $dir) { Stop-Hv '缺少 HV_DUMP_DIR。' }
    [void](New-HvDirectory $dir)
    $final = Join-HvPath $dir 'nextcloud.sql'
    $tmp = $final + '.tmp'
    $a = @(Get-HvComposeArgs) + @('exec', '-T', 'db', 'pg_dump', '-U', 'nextcloud', '-d', 'nextcloud', '--no-owner')
    $code = Invoke-HvNativeToFile -FilePath 'docker' -ArgumentList $a -OutFile $tmp
    $len = 0
    if ([System.IO.File]::Exists($tmp)) { $len = (New-Object System.IO.FileInfo($tmp)).Length }
    if ($code -ne 0 -or $len -lt 100) {
        Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
        Stop-Hv ('pg_dump 失败（退出码 ' + $code + '）。')
    }
    if ([System.IO.File]::Exists($final)) { Remove-Item -LiteralPath $final -Force }
    Move-Item -LiteralPath $tmp -Destination $final
    Write-HvOk ('数据库已导出：' + $final + '（' + (ConvertTo-HvSizeText $len) + '）')
}

function Invoke-HvBackup {
    param([switch]$Init, [switch]$Check)
    $envv = Assert-HvBackupConfigured
    Update-HvDerivedEnv
    $envv = Get-HvEnv
    Write-HvStep ('HomeVault 备份开始：' + (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))
    Initialize-HvResticRepo -Env $envv -AllowInit:$Init
    if (-not (Test-HvAppRunning)) { Stop-Hv 'Nextcloud 未运行：请先启动（.\windows\hv.ps1 up）再备份。' }
    [void](Write-HvComposeStorageFile)
    $maintOn = $false
    try {
        Write-HvInfo '开启维护模式（仅在导出数据库期间）...'
        [void](Invoke-HvOcc -OccArgs @('maintenance:mode', '--on') -Capture)
        $maintOn = $true
        Invoke-HvDbDump -Env $envv
    } finally {
        if ($maintOn) {
            $off = Invoke-HvOcc -OccArgs @('maintenance:mode', '--off') -Capture -AllowFailure
            if ($off.ExitCode -ne 0) { Write-HvErr '关闭维护模式失败！请手动运行：.\windows\hv.ps1 occ maintenance:mode --off' } else { Write-HvInfo '已关闭维护模式。' }
        }
    }
    $wgDir = Get-HvEnvDictValue $envv 'HV_WIN_WG_DIR'
    $paths = Get-HvBackupPaths -Storages (Get-HvStorageRows) -WinWireGuard ([bool]($wgDir -and [System.IO.Directory]::Exists($wgDir)))
    Write-HvStep 'restic backup ...'
    $b = Invoke-HvRestic -ResticArgs (Get-HvResticBackupArgs -Env $envv -Paths $paths) -Tee -AllowFailure
    $partial = $false
    if ($b.ExitCode -eq 3) { $partial = $true; Write-HvWarn 'restic：部分文件无法读取（退出码 3），快照不完整。' }
    elseif ($b.ExitCode -ne 0) { Stop-Hv ('restic backup 失败（退出码 ' + $b.ExitCode + '）。') $b.ExitCode }
    Write-HvStep '按保留策略清理旧快照（forget --prune）...'
    $f = Invoke-HvRestic -ResticArgs (Get-HvResticForgetArgs $envv) -Tee -AllowFailure
    if ($f.ExitCode -ne 0) { Write-HvWarn ('restic forget 失败（退出码 ' + $f.ExitCode + '）。') }
    if ($Check -or (Get-Date).DayOfWeek -eq [System.DayOfWeek]::Sunday) {
        Write-HvStep '校验备份（check --read-data-subset=5%）...'
        $c = Invoke-HvRestic -ResticArgs (Get-HvResticCheckArgs $envv) -Tee -AllowFailure
        if ($c.ExitCode -ne 0) { Stop-Hv ('restic check 失败（退出码 ' + $c.ExitCode + '）：备份仓库可能损坏！') $c.ExitCode }
    }
    if ($partial) { Stop-Hv '备份不完整（restic 退出码 3），请查看上面的警告。' 3 }
    if ($f.ExitCode -ne 0) { Stop-Hv '备份已完成，但清理旧快照失败。' $f.ExitCode }
    $state = New-HvDirectory (Get-HvPath 'state')
    Write-HvTextFile -Path (Join-HvPath $state 'last-backup-ok') -Content ((Get-Date).ToString('o') + "`n")
    Write-HvOk ('备份成功：' + (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))
}

function Register-HvBackupTask {
    param([string]$Time)
    Assert-HvWindows 'schedule-backup'
    $at = ConvertTo-HvTaskTime $Time
    $hv = Join-HvPath (Join-HvPath (Get-HvRoot) 'windows') 'hv.ps1'
    $log = Join-HvPath (Get-HvPath 'state') 'backup.log'
    [void](New-HvDirectory (Get-HvPath 'state'))
    $arg = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + $hv + '" backup --non-interactive --log "' + $log + '"'
    $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $arg -WorkingDirectory (Get-HvRoot)
    $trigger = New-ScheduledTaskTrigger -Daily -At $at
    $user = Get-HvDesktopUserName
    $principal = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Limited
    $settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Hours 23) -MultipleInstances IgnoreNew
    [void](Register-ScheduledTask -TaskName $script:HvBackupTask -Action $action -Trigger $trigger -Principal $principal -Settings $settings `
            -Description 'HomeVault：每日 restic 备份（Docker Desktop 需在该用户登录后运行）。日志：state\backup.log' -Force)
    Write-HvOk ('已创建计划任务 ' + $script:HvBackupTask + '：每天 ' + $at.ToString('HH:mm') + ' 以用户 ' + $user + ' 运行（日志 ' + $log + '）。')
}

function Invoke-HvCmdScheduleBackup {
    param([object[]]$Arguments = @())
    $p = Read-HvCommandArgs -Arguments $Arguments -Options @('time') -Switches @('remove')
    [void](Get-HvEnv)
    Assert-HvWindows 'schedule-backup'
    if (Test-HvOpt $p 'remove') {
        Unregister-ScheduledTask -TaskName $script:HvBackupTask -Confirm:$false -ErrorAction SilentlyContinue
        Write-HvOk ('已删除计划任务 ' + $script:HvBackupTask)
        return
    }
    $time = Get-HvOpt $p 'time' ''
    if ($time) {
        try { [void](ConvertTo-HvTaskTime $time) } catch { Stop-Hv $_.Exception.Message 2 }
        Update-HvEnv ([ordered]@{ HV_BACKUP_TIME = $time })
    } else { $time = Get-HvEnvValue 'HV_BACKUP_TIME' '03:30' }
    [void](Assert-HvBackupConfigured)
    Register-HvBackupTask -Time $time
}

function Invoke-HvCmdBackup {
    param([object[]]$Arguments = @())
    $p = Read-HvCommandArgs -Arguments $Arguments -Switches @('init', 'check') -Options @('log')
    $log = Get-HvOpt $p 'log' ''
    if ($log) { $script:HvLogFile = $log; [void](New-HvDirectory ([System.IO.Path]::GetDirectoryName($log))) }
    [void](Get-HvEnv)
    try {
        Invoke-HvBackup -Init:(Test-HvOpt $p 'init') -Check:(Test-HvOpt $p 'check')
    } catch {
        Write-HvLog ('备份失败：' + (Get-HvErrorMessage $_))
        throw
    }
}

# ---------------------------------------------------------------- restore

function New-HvRestoreOverlay {
    # Pure: compose overlay that re-mounts the backup sources read-write (merged by target path) for --full.
    return (@(
            '# 由 HomeVault restore --full 临时生成'
            'services:'
            '  backup:'
            '    volumes:'
            '      - ${HV_VOL_HTML:-nc_html}:/src/nextcloud-html'
            '      - ${HV_NC_DATA_PATH}:/src/nextcloud-data'
            '      - ${HV_VOL_CADDY_DATA:-caddy_data}:/src/caddy-data'
            '      - ${HV_DUMP_DIR:-hv_dumps}:/src/dumps'
        ) -join "`n") + "`n"
}

function Get-HvRestoreFullIncludes {
    return @('/src/nextcloud-html/config', '/src/nextcloud-html/custom_apps', '/src/nextcloud-html/themes',
        '/src/nextcloud-data', '/src/caddy-data', '/src/dumps')
}

function Invoke-HvRestoreFiles {
    param([System.Collections.IDictionary]$Env, [string]$Path, [string]$Snapshot)
    $ts = (Get-Date).ToString('yyyyMMdd-HHmmss')
    $dest = New-HvDirectory (Join-HvPath (Get-HvPath 'restore') $ts)
    Write-HvStep ('从快照 ' + $Snapshot + ' 恢复 ' + $Path + ' 到 ' + $dest)
    $r = Invoke-HvRestic -RunArgs @('-v', ($dest + ':/hv-restore')) -ResticArgs (@(Get-HvResticRepoArgs $Env) + @('restore', $Snapshot, '--target', '/hv-restore', '--include', $Path)) -Tee -AllowFailure
    if ($r.ExitCode -ne 0) { Stop-Hv ('恢复失败（restic 退出码 ' + $r.ExitCode + '）。') $r.ExitCode }
    Write-HvOk ('已恢复到：' + $dest)
    Write-HvInfo '文件保留了快照中的完整路径（src\...）。确认无误后，可把文件复制回原位置（例如通过网页上传，或复制到数据目录后运行 occ files:scan --all）。'
}

function Invoke-HvRestoreFull {
    param([System.Collections.IDictionary]$Env, [string]$Snapshot)
    Write-HvWarn '完整恢复（灾难恢复）会用快照覆盖：Nextcloud 配置/应用/主题、主数据目录、Caddy 证书数据，并重建数据库。当前数据库会被删除！'
    if (-not (Read-HvYesNo '确定要继续完整恢复吗？' $false)) { Stop-Hv '已取消。' }
    if (-not (Read-HvConfirmPhrase '这是不可撤销的操作。' 'RESTORE')) { Stop-Hv '已取消。' }
    $snap = Invoke-HvRestic -ResticArgs (@(Get-HvResticRepoArgs $Env) + @('snapshots', '--json', $Snapshot)) -Capture -AllowFailure
    if ($snap.ExitCode -ne 0 -or (Get-HvJsonSlice $snap.Text) -notmatch '"id"') { Stop-Hv ('找不到快照：' + $Snapshot) }
    $overlay = Join-HvPath (New-HvDirectory (Get-HvPath 'state')) 'compose.restore.yaml'
    Write-HvTextFile -Path $overlay -Content (New-HvRestoreOverlay)
    try {
        Write-HvStep '停止 app / cron / caddy ...'
        [void](Invoke-HvCompose -Arguments @('stop', 'app', 'cron', 'caddy'))
        [void](Invoke-HvCompose -Arguments @('up', '-d', 'db', 'redis'))
        Write-HvStep '从快照恢复文件（可能需要很长时间）...'
        $ra = @(Get-HvResticRepoArgs $Env) + @('restore', $Snapshot, '--target', '/')
        foreach ($inc in (Get-HvRestoreFullIncludes)) { $ra += @('--include', $inc) }
        $r = Invoke-HvRestic -ExtraFiles @($overlay) -ResticArgs $ra -Tee -AllowFailure
        if ($r.ExitCode -ne 0) { Stop-Hv ('文件恢复失败（restic 退出码 ' + $r.ExitCode + '）。') $r.ExitCode }
        $dump = Join-HvPath (Get-HvEnvDictValue $Env 'HV_DUMP_DIR') 'nextcloud.sql'
        if (-not [System.IO.File]::Exists($dump)) { Stop-Hv ('快照中没有数据库导出：' + $dump) }
        Write-HvStep '重建数据库 ...'
        [void](Invoke-HvCompose -Arguments @('exec', '-T', 'db', 'psql', '-v', 'ON_ERROR_STOP=1', '-U', 'nextcloud', '-d', 'postgres', '-c', 'DROP DATABASE IF EXISTS nextcloud WITH (FORCE)'))
        [void](Invoke-HvCompose -Arguments @('exec', '-T', 'db', 'psql', '-v', 'ON_ERROR_STOP=1', '-U', 'nextcloud', '-d', 'postgres', '-c', 'CREATE DATABASE nextcloud OWNER nextcloud'))
        [void](Invoke-HvCompose -Arguments @('cp', $dump, 'db:/tmp/hv-restore.sql'))
        try {
            [void](Invoke-HvCompose -Arguments @('exec', '-T', 'db', 'psql', '-q', '-v', 'ON_ERROR_STOP=1', '-U', 'nextcloud', '-d', 'nextcloud', '-f', '/tmp/hv-restore.sql'))
        } finally {
            [void](Invoke-HvCompose -Arguments @('exec', '-T', 'db', 'rm', '-f', '/tmp/hv-restore.sql') -AllowFailure -Quiet)
        }
        # the restored config.php carries the old DB password: make the database accept it and keep secrets\ in sync
        $pw = Invoke-HvCompose -Arguments @('run', '--rm', '--no-deps', '-T', '--entrypoint', 'php', 'app', '-r', 'include ''/var/www/html/config/config.php''; echo $CONFIG[''dbpassword''];') -Capture -AllowFailure
        $dbpw = ''
        if ($pw.ExitCode -eq 0) { $dbpw = ($pw.Output | Select-Object -Last 1) }
        if ($dbpw -match '^[A-Za-z0-9]{8,}$') {
            [void](Invoke-HvCompose -Arguments @('exec', '-T', 'db', 'psql', '-q', '-v', 'ON_ERROR_STOP=1', '-U', 'nextcloud', '-d', 'postgres') -InputText ("ALTER USER nextcloud WITH PASSWORD '" + $dbpw + "';") -Capture)
            if ((Read-HvSecret 'postgres_password') -ne $dbpw) { Write-HvSecret -Name 'postgres_password' -Value $dbpw; Write-HvInfo '已同步 secrets\postgres_password 为备份中的数据库密码。' }
        } else {
            Write-HvWarn '未能从恢复的 config.php 读取数据库密码；如 Nextcloud 无法连接数据库，请手动核对 dbpassword。'
        }
    } finally {
        Remove-Item -LiteralPath $overlay -Force -ErrorAction SilentlyContinue
    }
    Write-HvStep '启动全部服务 ...'
    [void](Invoke-HvCompose -Arguments @('up', '-d', '--remove-orphans'))
    [void](Wait-HvHealthy -TimeoutSec 900)
    [void](Invoke-HvOcc -OccArgs @('maintenance:mode', '--off') -Capture -AllowFailure)
    [void](Invoke-HvOcc -OccArgs @('maintenance:data-fingerprint'))
    Write-HvStep '重新扫描所有文件（occ files:scan --all）...'
    [void](Invoke-HvOcc -OccArgs @('files:scan', '--all') -AllowFailure)
    Write-HvOk '完整恢复完成。手机/电脑客户端可能会提示冲突，请按提示处理。'
}

function Invoke-HvCmdRestore {
    param([object[]]$Arguments = @())
    $p = Read-HvCommandArgs -Arguments $Arguments -Switches @('full') -Options @('files', 'snapshot', 'ls')
    $envv = Assert-HvBackupConfigured
    $snap = Get-HvOpt $p 'snapshot' 'latest'
    if (Test-HvOpt $p 'full') { Invoke-HvRestoreFull -Env $envv -Snapshot $snap; return }
    $files = Get-HvOpt $p 'files' ''
    if ($files) { Invoke-HvRestoreFiles -Env $envv -Path $files -Snapshot $snap; return }
    $ls = Get-HvOpt $p 'ls' ''
    if ($ls) {
        [void](Invoke-HvRestic -ResticArgs (@(Get-HvResticRepoArgs $envv) + @('ls', $snap, $ls)) -Tee)
        return
    }
    [void](Invoke-HvRestic -ResticArgs (@(Get-HvResticRepoArgs $envv) + @('snapshots', '--tag', 'homevault')) -Tee)
    Write-HvInfo '用法：'
    Write-HvInfo '  restore --ls /src/nextcloud-data/<用户>/files [--snapshot <ID>]     浏览快照内容'
    Write-HvInfo '  restore --files /src/nextcloud-data/<用户>/files/照片 [--snapshot <ID>]   恢复到 restore\<时间>\'
    Write-HvInfo '  restore --full [--snapshot <ID>]                                    灾难恢复（需要二次确认）'
}
