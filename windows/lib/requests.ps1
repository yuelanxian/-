# HomeVault Windows CLI - host runner for management-panel requests (SPEC section 15, panel/INTEGRATION.md section 5).
# The panel writes state\requests\<id>.json; `hv.ps1 requests process` (task HomeVault-Requests, every 2 minutes)
# runs allow-listed types only (backup | log-clean | log-retention), moves each file to state\requests\done\<id>.json
# BEFORE running it and writes done\<id>.result.json {"request","type","ok","finished","message"} afterwards.

$script:HvRequestTypes = @('backup', 'log-clean', 'log-retention')
$script:HvRequestMaxBytes = 65536
$script:HvRequestKeepDone = 200

# ---------------------------------------------------------------- pure helpers

function Test-HvRequestFileName {
    # Pure: <id>.json with a conservative character set; temp files (.tmp-*) and result files are not requests.
    param([AllowEmptyString()][string]$Name)
    if ($Name -cnotmatch '^[A-Za-z0-9_-][A-Za-z0-9._-]{0,127}\.json$') { return $false }
    return ($Name -notmatch '(?i)\.result\.json$')
}

function ConvertFrom-HvRequestText {
    # Pure: validate the content of a request file. Returns Valid/Type/Days/Error. The type must be one of the
    # allow-listed names (exact, case-sensitive); log-retention needs an integer "days" 1-365.
    param([AllowEmptyString()][AllowNull()][string]$Text)
    $res = [pscustomobject]@{ Valid = $false; Type = ''; Days = 0; Error = '' }
    $t = ([string]$Text).TrimStart([char]0xFEFF).Trim()
    if ($t -eq '') { $res.Error = '请求文件为空'; return $res }
    if ($t.Length -gt $script:HvRequestMaxBytes) { $res.Error = '请求文件过大'; return $res }
    # an object only (PowerShell 7 would unroll a one-element array)
    if (-not $t.StartsWith('{')) { $res.Error = '请求格式错误（应为 JSON 对象）'; return $res }
    $j = $null
    try { $j = ConvertFrom-Json -InputObject $t } catch { $res.Error = '请求文件不是有效的 JSON'; return $res }
    if ($null -eq $j -or $j -isnot [System.Management.Automation.PSCustomObject]) { $res.Error = '请求格式错误（应为 JSON 对象）'; return $res }
    # read properties directly: a function return would unroll ["backup"] into "backup"
    $type = $null
    $tp = $j.PSObject.Properties['type']
    if ($null -ne $tp) { $type = $tp.Value }
    if ($type -isnot [string] -or $type -eq '') { $res.Error = '缺少请求类型（type）'; return $res }
    if ($script:HvRequestTypes -cnotcontains $type) { $res.Error = '请求类型不在允许列表中（只允许 backup、log-clean、log-retention）'; return $res }
    if ($type -eq 'log-retention') {
        $d = $null
        $dp = $j.PSObject.Properties['days']
        if ($null -ne $dp) { $d = $dp.Value }
        $n = [long]-1
        if ($d -is [int] -or $d -is [long] -or $d -is [int16] -or $d -is [byte]) { $n = [long]$d }
        elseif ($d -is [double] -or $d -is [decimal] -or $d -is [single]) { if ([Math]::Floor([double]$d) -eq [double]$d -and [Math]::Abs([double]$d) -lt 100000) { $n = [long]$d } }
        elseif ($d -is [string] -and $d -match '^\s*[0-9]{1,3}\s*$') { $n = [long]$d.Trim() }
        if ($n -lt 1 -or $n -gt 365) { $res.Error = '日志保留天数（days）必须是 1 到 365 之间的整数'; return $res }
        $res.Days = [int]$n
    }
    $res.Type = $type
    $res.Valid = $true
    return $res
}

function New-HvRequestResult {
    # Pure: content of done\<id>.result.json (same keys as the Linux runner: id, request, type, ok, finished, message).
    param([string]$RequestFile, [AllowEmptyString()][string]$Type, [bool]$Ok, [AllowEmptyString()][string]$Message, [datetime]$Now)
    $t = $Type
    if (-not $t) { $t = 'unknown' }
    $id = $RequestFile
    if ($id -match '(?i)\.json$') { $id = $id.Substring(0, $id.Length - 5) }
    return [ordered]@{ id = $id; request = $RequestFile; type = $t; ok = $Ok; finished = (Format-HvIsoTime $Now); message = $Message }
}

# ---------------------------------------------------------------- actions

function Test-HvBackupTaskRunning {
    if (-not (Test-HvWindows)) { return $false }
    $name = 'HomeVault-Backup'
    if ($script:HvBackupTask) { $name = $script:HvBackupTask }
    try {
        $t = Get-ScheduledTask -TaskName $name -ErrorAction Stop
        return ([string]$t.State -eq 'Running')
    } catch { return $false }
}

function Invoke-HvBackupLogged {
    # Run the backup (hv.ps1 backup) with its messages also written to <HV_LOG_DIR>\backup\backup-YYYYMMDD-HHMMSS.log.
    # Returns the log path ('' if the log directory is not available). Throws when the backup fails.
    param([switch]$Check)
    $prev = $script:HvLogFile
    $log = ''
    try {
        $dir = New-HvDirectory (Join-HvPath (Get-HvLogDir) 'backup')
        $log = Join-HvPath $dir ('backup-' + (Get-Date).ToString('yyyyMMdd-HHmmss', [System.Globalization.CultureInfo]::InvariantCulture) + '.log')
    } catch { $log = '' }
    $a = @()
    if ($log) { $a += @('--log', $log) }
    if ($Check) { $a += '--check' }
    try {
        Invoke-HvCmdBackup -Arguments $a | Out-Null
    } finally {
        $script:HvLogFile = $prev
    }
    return $log
}

function Invoke-HvRequestAction {
    # Run one validated request. Never throws; returns Ok + Message (Chinese, shown in the panel).
    param([string]$Type, [int]$Days = 0)
    try {
        switch ($Type) {
            'backup' {
                if (Test-HvBackupTaskRunning) { return [pscustomobject]@{ Ok = $false; Message = '计划备份任务正在运行，本次请求已跳过，请稍后再试。' } }
                $log = Invoke-HvBackupLogged
                $m = '备份完成'
                if ($log) { $m += '（日志：backup\' + [System.IO.Path]::GetFileName($log) + '）' }
                return [pscustomobject]@{ Ok = $true; Message = $m }
            }
            'log-clean' {
                $n = Invoke-HvLogClean
                return [pscustomobject]@{ Ok = $true; Message = ('已清理 ' + $n + ' 个超过保留天数的日志文件') }
            }
            'log-retention' {
                $d = Set-HvLogRetention -Days $Days
                return [pscustomobject]@{ Ok = $true; Message = ('日志保留天数已设为 ' + $d + ' 天') }
            }
        }
        return [pscustomobject]@{ Ok = $false; Message = '请求类型不在允许列表中' }
    } catch {
        return [pscustomobject]@{ Ok = $false; Message = (Get-HvErrorMessage $_) }
    }
}

# ---------------------------------------------------------------- runner

function Write-HvRequestResult {
    param([string]$DoneDir, [string]$FileName, [AllowEmptyString()][string]$Type, [bool]$Ok, [AllowEmptyString()][string]$Message)
    $id = $FileName.Substring(0, $FileName.Length - 5)
    Write-HvJsonFile -Path (Join-HvPath $DoneDir ($id + '.result.json')) -Value (New-HvRequestResult -RequestFile $FileName -Type $Type -Ok $Ok -Message $Message -Now (Get-Date))
}

function Get-HvPendingRequestFiles {
    param([string]$Dir)
    if (-not [System.IO.Directory]::Exists($Dir) -or (Test-HvLinkItem $Dir)) { return @() }
    return @(Get-ChildItem -LiteralPath $Dir -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -like '*.json' -and -not $_.Name.StartsWith('.') } | Sort-Object Name)
}

function Remove-HvOldRequestResults {
    # Keep the newest request/result files in done\ (only regular *.json files; links are never followed).
    param([string]$DoneDir, [int]$Keep = 200)
    if (Test-HvLinkItem $DoneDir) { return }
    $all = @(Get-ChildItem -LiteralPath $DoneDir -File -Filter '*.json' -ErrorAction SilentlyContinue |
            Where-Object { -not (Test-HvLinkItem $_) } | Sort-Object LastWriteTime -Descending)
    if ($all.Count -le $Keep) { return }
    foreach ($x in $all[$Keep..($all.Count - 1)]) { try { [System.IO.File]::Delete($x.FullName) } catch { } }
}

function Get-HvRequestDoneDir {
    # state\requests\done as a real directory. The panel container can write below state\requests: a link or
    # file planted as done\ is moved aside (never followed) and the directory re-created, as on Linux.
    param([string]$RequestsDir)
    if (Test-HvLinkItem $RequestsDir) { Stop-Hv ('state\requests 是符号链接/联接点，拒绝处理管理面板请求：' + $RequestsDir) }
    $done = Join-HvPath $RequestsDir 'done'
    if ((Test-HvLinkItem $done) -or [System.IO.File]::Exists($done)) {
        $aside = Join-HvPath $RequestsDir ('.done-invalid-' + (Get-Date).ToString('yyyyMMddHHmmss', [System.Globalization.CultureInfo]::InvariantCulture) + '-' + (New-HvRandomString 6))
        Write-HvWarn ('state\requests\done 不是普通目录，已移到 ' + [System.IO.Path]::GetFileName($aside) + ' 并重建。')
        if ([System.IO.Directory]::Exists($done)) { [System.IO.Directory]::Move($done, $aside) } else { [System.IO.File]::Move($done, $aside) }
    }
    return (New-HvDirectory $done)
}

function Invoke-HvRequestsProcess {
    # Process pending requests in name (= time) order. Returns the number of request files handled.
    $dir = Join-HvPath (Get-HvStateDir) 'requests'
    $files = @(Get-HvPendingRequestFiles $dir)
    if ($files.Count -eq 0) { return 0 }
    $done = Get-HvRequestDoneDir $dir
    $n = 0
    $backupResult = $null
    foreach ($f in $files) {
        $name = $f.Name
        if ((Test-HvLinkItem $f) -or -not (Test-HvRequestFileName $name)) {
            Write-HvLog ('忽略并删除不合规的请求文件：' + $name)
            try { [System.IO.File]::Delete($f.FullName) } catch { }
            continue
        }
        if ($f.Length -gt $script:HvRequestMaxBytes) {
            $req = [pscustomobject]@{ Valid = $false; Type = ''; Days = 0; Error = '请求文件过大' }
        } else {
            $text = $null
            try { $text = [System.IO.File]::ReadAllText($f.FullName, [System.Text.Encoding]::UTF8) } catch { continue }  # still being written: next run
            $req = ConvertFrom-HvRequestText $text
        }
        try { Move-HvFileReplace -Source $f.FullName -Destination (Join-HvPath $done $name) } catch { Write-HvWarn ('无法移动请求文件 ' + $name + '：' + $_.Exception.Message); continue }
        $n++
        if (-not $req.Valid) {
            Write-HvWarn ('管理面板请求 ' + $name + ' 被拒绝：' + $req.Error)
            Write-HvRequestResult -DoneDir $done -FileName $name -Type '' -Ok $false -Message ('请求无效：' + $req.Error)
            continue
        }
        $label = $req.Type
        if ($req.Type -eq 'log-retention') { $label += ' ' + $req.Days + ' 天' }
        Write-HvStep ('执行管理面板请求：' + $label + '（' + $name + '）')
        if ($req.Type -eq 'backup' -and $null -ne $backupResult) {
            $r = [pscustomobject]@{ Ok = $backupResult.Ok; Message = ('与同一批次的备份请求合并：' + $backupResult.Message) }
        } else {
            $r = Invoke-HvRequestAction -Type $req.Type -Days $req.Days
            if ($req.Type -eq 'backup') { $backupResult = $r }
        }
        Write-HvRequestResult -DoneDir $done -FileName $name -Type $req.Type -Ok ([bool]$r.Ok) -Message ([string]$r.Message)
        if ($r.Ok) { Write-HvOk ($label + '：' + $r.Message) } else { Write-HvWarn ($label + ' 失败：' + $r.Message) }
    }
    Remove-HvOldRequestResults -DoneDir $done -Keep $script:HvRequestKeepDone
    return $n
}

function Invoke-HvRequests {
    # hv.ps1 requests process - run by the task HomeVault-Requests every 2 minutes (also refreshes the status files).
    param([Parameter(ValueFromRemainingArguments = $true)][object[]]$Arguments = @())
    $p = Read-HvCommandArgs -Arguments $Arguments
    $sub = 'process'
    if ($p.Positional.Count -gt 0) { $sub = $p.Positional[0].ToLowerInvariant() }
    if ($sub -ne 'process') { Stop-Hv '用法：requests process（执行管理面板提交的请求；计划任务 HomeVault-Requests 每 2 分钟自动运行）' 2 }
    [void](Get-HvEnv)
    $pending = @(Get-HvPendingRequestFiles (Join-HvPath (Get-HvStateDir) 'requests'))
    if ($pending.Count -gt 0) { Start-HvUxLog 'requests process' }  # nothing to do = no log line every 2 minutes
    $n = Invoke-HvRequestsProcess
    try { Update-HvStatusFile -RequestsRun } catch { Write-HvWarn ('写入 state\status.json 失败：' + (Get-HvErrorMessage $_)) }
    try { [void](Update-HvVpnStatusFile) } catch { }
    if ($n -gt 0) { Write-HvInfo ('已处理 ' + $n + ' 个管理面板请求。') }
}
