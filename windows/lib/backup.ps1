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
        '--exclude', '/src/project/restore',
        '--exclude', '/src/project/state/backup.lock')
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

function Get-HvNextDailyRun {
    # Pure: next local occurrence of "HH:MM" strictly after Now ($null when the time is invalid).
    param([string]$Time, [datetime]$Now)
    if ($Time -notmatch '^\s*(\d{1,2}):(\d{2})\s*$') { return $null }
    $h = [int]$Matches[1]; $m = [int]$Matches[2]
    if ($h -gt 23 -or $m -gt 59) { return $null }
    $c = $Now.Date.AddHours($h).AddMinutes($m)
    if ($c -le $Now) { $c = $c.AddDays(1) }
    return $c
}

function ConvertFrom-HvResticTime {
    # Pure: restic/Go timestamp (up to 9 fractional digits) or DateTime (PS 7's ConvertFrom-Json) -> UTC DateTime; $null if invalid.
    param([AllowNull()]$Value)
    if ($null -eq $Value) { return $null }
    if ($Value -is [datetime]) { return $Value.ToUniversalTime() }
    $t = [regex]::Replace(([string]$Value).Trim(), '(\.\d{7})\d+', '$1')
    $dto = [System.DateTimeOffset]::MinValue
    if ([System.DateTimeOffset]::TryParse($t, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::AssumeUniversal, [ref]$dto)) { return $dto.UtcDateTime }
    return $null
}

function Get-HvLatestSnapshotStats {
    # Pure: canonical BackupStats from the newest snapshot's summary in `restic snapshots --json` output
    # (restic >= 0.17). $null when there is none, or when it is older than -NotBefore (this run made no snapshot).
    param([AllowEmptyString()][string]$Json, $NotBefore = $null)
    $t = ([string]$Json).Trim()
    if (-not $t.StartsWith('[')) { return $null }
    $best = $null; $bestTime = $null
    foreach ($snap in (ConvertFrom-Json -InputObject $t)) {
        if ($null -eq $snap) { continue }
        $tm = ConvertFrom-HvResticTime (Get-HvPropValue $snap 'time')
        if ($null -eq $tm) { continue }
        if ($null -eq $bestTime -or $tm -gt $bestTime) { $best = $snap; $bestTime = $tm }
    }
    if ($null -eq $best) { return $null }
    if ($null -ne $NotBefore -and $bestTime -lt ([datetime]$NotBefore).ToUniversalTime()) { return $null }
    $sum = Get-HvPropValue $best 'summary'
    if ($null -eq $sum) { return $null }
    $st = [ordered]@{}
    foreach ($k in @('files_new', 'files_changed', 'data_added', 'total_files_processed', 'total_bytes_processed')) {
        $v = Get-HvPropValue $sum $k 0
        $n = [int64]0
        [void][int64]::TryParse([string]$v, [ref]$n)
        $st[$k] = $n
    }
    return $st
}

function Get-HvRepositoryDisplay {
    # Pure: repository shown in the panel - local path or S3 URL without any user:password@ part.
    param([System.Collections.IDictionary]$Env)
    $t = Get-HvEnvDictValue $Env 'HV_BACKUP_TARGET'
    if ($t -eq 's3') { return ([string](Get-HvEnvDictValue $Env 'HV_BACKUP_S3_REPO') -replace '://[^/@]*@', '://') }
    if ($t -eq 'local') { return (Get-HvEnvDictValue $Env 'HV_BACKUP_LOCAL_PATH') }
    return ''
}

function New-HvBackupStatus {
    # Pure: state/backup-status.json in the canonical shape (panel/internal/hoststate/types.go BackupStatus).
    param(
        [System.Collections.IDictionary]$Env, [string]$State, [datetime]$Started, [datetime]$Now,
        $Finished = $null, [AllowEmptyString()][string]$LastSuccess = '', [AllowEmptyString()][string]$Message = '',
        [AllowEmptyString()][string]$LogFile = '', $NextRun = $null, $ExitCode = $null, $Stats = $null
    )
    $o = [ordered]@{}
    $o['updated'] = Format-HvIsoTime $Now
    $o['state'] = $State
    $o['last_run'] = Format-HvIsoTime $Started
    if ($null -ne $Finished) {
        $o['last_finished'] = Format-HvIsoTime ([datetime]$Finished)
        $o['duration_seconds'] = [Math]::Round((([datetime]$Finished) - $Started).TotalSeconds, 1)
    } else {
        $o['last_finished'] = $null
        $o['duration_seconds'] = 0
    }
    if ($LastSuccess) { $o['last_success'] = $LastSuccess } else { $o['last_success'] = $null }
    $o['message'] = $Message
    $o['log_file'] = $LogFile
    $o['target'] = Get-HvEnvDictValue $Env 'HV_BACKUP_TARGET'
    $o['repository'] = Get-HvRepositoryDisplay $Env
    $o['schedule'] = Get-HvEnvDictValue $Env 'HV_BACKUP_TIME' '03:30'
    if ($null -ne $NextRun) { $o['next_run'] = Format-HvIsoTime ([datetime]$NextRun) }
    if ($null -ne $ExitCode) { $o['exit_code'] = [int]$ExitCode }
    if ($null -ne $Stats) { $o['stats'] = $Stats }
    return $o
}

function Get-HvPathRelativeTo {
    # Pure: File relative to Dir with '/' separators ('' when File is not below Dir; case-insensitive like NTFS).
    param([AllowEmptyString()][string]$Dir, [AllowEmptyString()][string]$File)
    if (-not $Dir -or -not $File) { return '' }
    $d = ($Dir -replace '\\', '/').TrimEnd('/') + '/'
    $f = ($File -replace '\\', '/')
    if (-not $f.StartsWith($d, [System.StringComparison]::OrdinalIgnoreCase)) { return '' }
    return $f.Substring($d.Length)
}

function Get-HvBackupLogRelPath {
    # Pure: log path relative to HV_LOG_DIR (what the panel links to).
    param([datetime]$Started)
    return ('backup/backup-' + $Started.ToString('yyyyMMdd-HHmmss', [System.Globalization.CultureInfo]::InvariantCulture) + '.log')
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

function Test-HvDumpComplete {
    # pg_dump plain SQL ends with "-- PostgreSQL database dump complete" (checks the last 4 KB only).
    param([string]$Path)
    $fs = [System.IO.File]::OpenRead($Path)
    try {
        $n = [int][Math]::Min([int64]4096, $fs.Length)
        [void]$fs.Seek(-$n, [System.IO.SeekOrigin]::End)
        $buf = New-Object byte[] $n
        $read = 0
        while ($read -lt $n) {
            $k = $fs.Read($buf, $read, $n - $read)
            if ($k -le 0) { break }
            $read += $k
        }
    } finally { $fs.Dispose() }
    return ([System.Text.Encoding]::UTF8.GetString($buf, 0, $read)).Contains('PostgreSQL database dump complete')
}

function Invoke-HvDbDump {
    # pg_dump (plain SQL) into HV_DUMP_DIR\nextcloud.sql via a temp file.
    param([System.Collections.IDictionary]$Env)
    $dir = Get-HvEnvDictValue $Env 'HV_DUMP_DIR'
    if (-not $dir) { Stop-Hv '缺少 HV_DUMP_DIR。' }
    [void](New-HvDirectory $dir)
    $final = Join-HvPath $dir 'nextcloud.sql'
    $tmp = $final + '.tmp'
    # owners are kept (tables belong to Nextcloud's own role, e.g. oc_hvadmin; restore --full recreates it first)
    $a = @(Get-HvComposeArgs) + @('exec', '-T', 'db', 'pg_dump', '-U', 'nextcloud', '-d', 'nextcloud', '--no-password')
    $code = Invoke-HvNativeToFile -FilePath 'docker' -ArgumentList $a -OutFile $tmp
    $len = 0
    if ([System.IO.File]::Exists($tmp)) { $len = (New-Object System.IO.FileInfo($tmp)).Length }
    if ($code -ne 0 -or $len -lt 100 -or -not (Test-HvDumpComplete $tmp)) {
        Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
        Stop-Hv ('pg_dump 失败或导出不完整（退出码 ' + $code + '）。')
    }
    if ([System.IO.File]::Exists($final)) { Remove-Item -LiteralPath $final -Force }
    Move-Item -LiteralPath $tmp -Destination $final
    Write-HvOk ('数据库已导出：' + $final + '（' + (ConvertTo-HvSizeText $len) + '）')
}

function Invoke-HvBackupCore {
    # (repository already opened) maintenance mode only around pg_dump -> restic backup -> forget --prune -> check (Sundays / --check).
    param([System.Collections.IDictionary]$Env, [switch]$Check)
    $envv = $Env
    if (-not (Test-HvAppRunning)) { Stop-Hv 'Nextcloud 未运行：请先启动（.\windows\hv.ps1 up）再备份。' }
    $maintOn = $false
    try {
        Write-HvInfo '开启维护模式（仅在导出数据库期间）...'
        [void](Invoke-HvOcc -OccArgs @('maintenance:mode', '--on') -Capture)
        $maintOn = $true
        Invoke-HvDbDump -Env $envv
    } finally {
        if ($maintOn) {
            $off = Invoke-HvOcc -OccArgs @('maintenance:mode', '--off') -Capture -AllowFailure
            if ($off.ExitCode -ne 0) {
                Start-Sleep -Seconds 3
                $off = Invoke-HvOcc -OccArgs @('maintenance:mode', '--off') -Capture -AllowFailure
            }
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
    if ($partial) { Stop-Hv '备份不完整（restic 退出码 3：部分文件无法读取），请查看备份日志中的警告。' 3 }
    if ($f.ExitCode -ne 0) { Stop-Hv '备份已完成，但清理旧快照失败。' $f.ExitCode }
}

function Get-HvBackupStatePath { param([string]$Name) return (Join-HvPath (New-HvDirectory (Get-HvPath 'state')) $Name) }

function Get-HvLastBackupOk {
    $f = Get-HvBackupStatePath 'last-backup-ok'
    if (-not [System.IO.File]::Exists($f)) { return '' }
    return (Read-HvTextFile $f).Trim()
}

function Get-HvBackupNextRun {
    # Next run of the HomeVault-Backup task ($null when it is not scheduled).
    if (-not (Test-HvWindows)) { return $null }
    try {
        $t = Get-ScheduledTask -TaskName $script:HvBackupTask -ErrorAction Stop
        if ([string]$t.State -eq 'Disabled') { return $null }
        $i = $t | Get-ScheduledTaskInfo -ErrorAction Stop
        if ($i.NextRunTime) { return [datetime]$i.NextRunTime }
        return (Get-HvNextDailyRun -Time (Get-HvEnvValue 'HV_BACKUP_TIME' '03:30') -Now (Get-Date))
    } catch { return $null }
}

function Save-HvSnapshotsJson {
    # state\snapshots.json = raw `restic snapshots --json` (byte-exact); returns the JSON text ('' on failure).
    param([System.Collections.IDictionary]$Env)
    $final = Get-HvBackupStatePath 'snapshots.json'
    $tmp = New-HvTempPath $final
    $text = ''
    try {
        $a = @(Get-HvComposeArgs -Tools) + @('run', '--rm', '--no-deps', '-T', 'backup') + @(Get-HvResticRepoArgs $Env) +
            @('snapshots', '--json', '--host', 'homevault', '--tag', 'homevault')
        $code = Invoke-HvNativeToFile -FilePath 'docker' -ArgumentList $a -OutFile $tmp
        if ([System.IO.File]::Exists($tmp)) { $text = Read-HvTextFile $tmp }
        if ($code -ne 0 -or -not $text.Trim().StartsWith('[')) { throw ('restic snapshots 退出码 ' + $code) }
        Move-HvFileReplace -Source $tmp -Destination $final
        return $text
    } catch {
        Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
        Write-HvWarn ('未能更新快照列表 state\snapshots.json：' + (Get-HvErrorMessage $_))
        return ''
    }
}

function Save-HvBackupStatus {
    param([System.Collections.IDictionary]$Status)
    try { Write-HvJsonFile -Path (Get-HvBackupStatePath 'backup-status.json') -Value $Status } catch { Write-HvWarn ('无法写入 state\backup-status.json：' + $_.Exception.Message) }
}

function Enter-HvBackupLock {
    # Exclusive lock so a scheduled backup and a panel request never run restic at the same time. Readers stay
    # allowed (FileShare.Read): restic reads the project folder through Docker Desktop's file sharing, and a file
    # opened with FileShare.None there fails with a sharing violation (= restic exit 3, "partial" every time).
    $f = Get-HvBackupStatePath 'backup.lock'
    try {
        return [System.IO.File]::Open($f, [System.IO.FileMode]::OpenOrCreate, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::Read)
    } catch {
        Stop-Hv '另一个备份任务正在运行（state\backup.lock 被占用），请稍后再试。' 11
    }
}

function Invoke-HvBackup {
    # Full backup job (CLI, scheduled task, panel request): own log file HV_LOG_DIR\backup\backup-<time>.log, lock,
    # state\backup-status.json (running -> ok | partial | failed), state\snapshots.json, state\last-backup-ok.
    param([switch]$Init, [switch]$Check, [string]$LogFile = '')
    $envv = Get-HvEnv
    $t = Get-HvEnvDictValue $envv 'HV_BACKUP_TARGET'
    if ($t -ne 'local' -and $t -ne 's3') { [void](Assert-HvBackupConfigured) }
    Update-HvDerivedEnv
    $envv = Get-HvEnv
    $started = Get-Date
    $logDir = Get-HvEnvLogDir
    if (-not $LogFile -and $logDir) {
        $LogFile = Join-HvPath (Join-HvPath $logDir 'backup') ([System.IO.Path]::GetFileName((Get-HvBackupLogRelPath $started)))
    }
    # the panel links to log_file relative to HV_LOG_DIR (also for --log paths chosen by the request runner)
    $logRel = Get-HvPathRelativeTo -Dir $logDir -File $LogFile
    $prevLog = $script:HvLogFile
    if ($LogFile) {
        try { [void](New-HvDirectory ([System.IO.Path]::GetDirectoryName($LogFile))) } catch { }
        Write-HvLog ('备份开始，日志：' + $LogFile)
        $script:HvLogFile = $LogFile
    }
    $failure = $null
    $lock = $null
    try {
        $lock = Enter-HvBackupLock
        Save-HvBackupStatus (New-HvBackupStatus -Env $envv -State 'running' -Started $started -Now (Get-Date) -LastSuccess (Get-HvLastBackupOk) `
                -Message '备份进行中' -LogFile $logRel -NextRun (Get-HvBackupNextRun))
        $state = 'ok'; $code = 0; $msg = '备份成功'; $repoReady = $false
        try {
            Write-HvStep ('HomeVault 备份开始：' + $started.ToString('yyyy-MM-dd HH:mm:ss'))
            [void](Assert-HvBackupConfigured)
            [void](Write-HvComposeStorageFile)
            Initialize-HvResticRepo -Env $envv -AllowInit:$Init
            $repoReady = $true
            Invoke-HvBackupCore -Env $envv -Check:$Check
        } catch {
            $failure = $_
            $code = Get-HvExitCodeFromError $_
            if ($code -eq 0) { $code = 1 }
            $msg = Get-HvErrorMessage $_
            $state = 'failed'
            if ($code -eq 3) { $state = 'partial' }
            Write-HvErr ('备份未成功：' + $msg)
        }
        $finished = Get-Date
        if ($state -eq 'ok') {
            Write-HvJsonFile -Path (Get-HvBackupStatePath 'last-backup-ok') -Value ((Format-HvIsoTime $finished) + "`n") -Raw
            Write-HvOk ('备份成功：' + $finished.ToString('yyyy-MM-dd HH:mm:ss') + '（用时 ' + [int]($finished - $started).TotalMinutes + ' 分钟）')
        }
        $stats = $null
        if ($repoReady) {
            $snap = Save-HvSnapshotsJson -Env $envv
            if ($snap) { try { $stats = Get-HvLatestSnapshotStats -Json $snap -NotBefore $started.AddMinutes(-2) } catch { $stats = $null } }
        }
        Save-HvBackupStatus (New-HvBackupStatus -Env $envv -State $state -Started $started -Now (Get-Date) -Finished $finished `
                -LastSuccess (Get-HvLastBackupOk) -Message $msg -LogFile $logRel -NextRun (Get-HvBackupNextRun) -ExitCode $code -Stats $stats)
    } finally {
        if ($lock) { $lock.Dispose() }
        $script:HvLogFile = $prevLog
    }
    if ($null -ne $failure) {
        if ($LogFile) { Write-HvInfo ('备份日志：' + $LogFile) }
        throw $failure
    }
}

function Register-HvBackupTask {
    param([string]$Time)
    Assert-HvWindows 'schedule-backup'
    $at = ConvertTo-HvTaskTime $Time
    $hv = Join-HvPath (Join-HvPath (Get-HvRoot) 'windows') 'hv.ps1'
    $log = Join-HvPath (Get-HvEnvLogDir) 'backup'
    $arg = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + $hv + '" backup --non-interactive'
    $ps = Join-HvPath ([System.Environment]::GetEnvironmentVariable('SystemRoot')) 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $action = New-ScheduledTaskAction -Execute $ps -Argument $arg -WorkingDirectory (Get-HvRoot)
    $trigger = New-ScheduledTaskTrigger -Daily -At $at
    $user = Get-HvDesktopUserName
    $principal = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Limited
    $settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Hours 23) -MultipleInstances IgnoreNew
    [void](Register-ScheduledTask -TaskName $script:HvBackupTask -Action $action -Trigger $trigger -Principal $principal -Settings $settings `
            -Description ('HomeVault：每日 restic 备份（Docker Desktop 需在该用户登录后运行）。日志：' + $log) -Force)
    Write-HvOk ('已创建计划任务 ' + $script:HvBackupTask + '：每天 ' + $at.ToString('HH:mm') + ' 以用户 ' + $user + ' 运行（日志在 ' + $log + '）。')
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
    $p = Read-HvCommandArgs -Arguments $Arguments -Switches @('init', 'check', 'unlock', 'snapshots', 'list') -Options @('log')
    [void](Get-HvEnv)
    if ((Test-HvOpt $p 'unlock') -or (Test-HvOpt $p 'snapshots') -or (Test-HvOpt $p 'list')) {
        $envv = Assert-HvBackupConfigured
        if (Test-HvOpt $p 'unlock') { [void](Invoke-HvRestic -ResticArgs (@(Get-HvResticRepoArgs $envv) + @('unlock')) -Tee); Write-HvOk '已清除过期的仓库锁。'; return }
        [void](Invoke-HvRestic -ResticArgs (@(Get-HvResticRepoArgs $envv) + @('snapshots', '--host', 'homevault', '--tag', 'homevault')) -Tee)
        [void](Save-HvSnapshotsJson -Env $envv)
        return
    }
    Invoke-HvBackup -Init:(Test-HvOpt $p 'init') -Check:(Test-HvOpt $p 'check') -LogFile (Get-HvOpt $p 'log' '')
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

function Test-HvSqlIdentifier {
    param([AllowEmptyString()][string]$Name)
    return ($Name -cmatch '^[A-Za-z0-9_]{1,63}$')
}

function New-HvRestoreDbSql {
    # Pure: SQL (run as the postgres superuser "nextcloud" on database postgres) that (re)creates the Nextcloud
    # role with the password from the restored config.php and an empty database owned by it (same as the bash CLI).
    param([string]$User, [AllowEmptyString()][string]$Password, [string]$Name)
    if (-not (Test-HvSqlIdentifier $User) -or -not (Test-HvSqlIdentifier $Name)) { throw ('config.php 中的数据库用户名/库名格式异常：' + $User + ' / ' + $Name) }
    $q = [string][char]39
    $l = @()
    if ($User -ne 'nextcloud') {
        $pw = $q + ($Password -replace $q, ($q + $q)) + $q
        $l += ('DO $hv$BEGIN IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = ' + $q + $User + $q + ') THEN CREATE ROLE "' + $User + '" LOGIN PASSWORD ' + $pw +
            '; ELSE ALTER ROLE "' + $User + '" WITH LOGIN PASSWORD ' + $pw + '; END IF; END$hv$;')
    }
    $l += ('DROP DATABASE IF EXISTS "' + $Name + '" WITH (FORCE);')
    $l += ('CREATE DATABASE "' + $Name + '" OWNER "' + $User + '";')
    return (($l -join "`n") + "`n")
}

function ConvertFrom-HvDbConfigOutput {
    # Pure: the three lines "dbuser / dbpassword / dbname" printed by PHP -> object (throws when incomplete).
    param([string[]]$Lines = @())
    $x = @(@($Lines) | ForEach-Object { ([string]$_).TrimEnd("`r") })
    if ($x.Count -lt 3 -or -not $x[$x.Count - 3] -or -not $x[$x.Count - 1]) { throw '无法从恢复的 config.php 读取数据库配置（dbuser / dbname）。' }
    return [pscustomobject]@{ User = $x[$x.Count - 3]; Password = $x[$x.Count - 2]; Name = $x[$x.Count - 1] }
}

function Get-HvRestoredDbConfig {
    # dbuser / dbpassword / dbname of the restored config.php (one-off app container; nothing is printed).
    $php = 'include "/var/www/html/config/config.php"; echo ($CONFIG["dbuser"] ?? ""), PHP_EOL, ($CONFIG["dbpassword"] ?? ""), PHP_EOL, ($CONFIG["dbname"] ?? "nextcloud"), PHP_EOL;'
    $r = Invoke-HvCompose -Arguments @('run', '--rm', '--no-deps', '-T', '--entrypoint', 'php', 'app', '-r', $php) -Capture -AllowFailure
    if ($r.ExitCode -ne 0) { Stop-Hv ('无法从恢复的 config.php 读取数据库配置（退出码 ' + $r.ExitCode + '）。') }
    try { return (ConvertFrom-HvDbConfigOutput -Lines $r.Output) } catch { Stop-Hv $_.Exception.Message }
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
    # the overlay makes the backup sources writable: keep it out of state\ (the panel container can write there)
    $overlay = Join-HvPath ([System.IO.Path]::GetTempPath()) ('homevault-restore-' + (New-HvRandomString 12) + '.yaml')
    Write-HvNewTextFile -Path $overlay -Content (New-HvRestoreOverlay)
    Set-HvPrivateAcl -Path $overlay
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
        # the restored config.php names the database role Nextcloud uses (normally oc_<admin>, created by the installer):
        # recreate that role with the backed-up password, then the database owned by it, then import (owners kept)
        $db = Get-HvRestoredDbConfig
        Write-HvStep ('重建数据库 ' + $db.Name + '（所有者 ' + $db.User + '）...')
        # stdin carries the role password: on failure show only the psql error lines, never the SQL (no -Tee, no log)
        $dbr = Invoke-HvCompose -Arguments @('exec', '-T', 'db', 'psql', '-q', '-v', 'ON_ERROR_STOP=1', '-U', 'nextcloud', '-d', 'postgres') `
            -InputText (New-HvRestoreDbSql -User $db.User -Password $db.Password -Name $db.Name) -Capture -AllowFailure
        if ($dbr.ExitCode -ne 0) {
            $errLine = @(@($dbr.StdErr) + @($dbr.Output) | Where-Object { [string]$_ -match '^(psql:.*)?ERROR:' } | ForEach-Object { ([string]$_ -replace "PASSWORD\s+'[^']*'", "PASSWORD '***'") } | Select-Object -First 1)
            Stop-Hv ('重建数据库失败（psql 退出码 ' + $dbr.ExitCode + '）' + $(if ($errLine.Count -gt 0) { '：' + $errLine[0] } else { '' })) $dbr.ExitCode
        }
        [void](Invoke-HvCompose -Arguments @('cp', $dump, 'db:/tmp/hv-restore.sql'))
        try {
            Write-HvInfo ('导入数据库转储（' + (ConvertTo-HvSizeText (New-Object System.IO.FileInfo($dump)).Length) + '）...')
            [void](Invoke-HvCompose -Arguments @('exec', '-T', 'db', 'psql', '-q', '-v', 'ON_ERROR_STOP=1', '-U', 'nextcloud', '-d', $db.Name, '-f', '/tmp/hv-restore.sql') -Capture)
        } finally {
            [void](Invoke-HvCompose -Arguments @('exec', '-T', 'db', 'rm', '-f', '/tmp/hv-restore.sql') -AllowFailure -Quiet)
        }
        Write-HvOk '数据库已恢复。'
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
