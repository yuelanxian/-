# HomeVault Windows CLI - logs (SPEC section 14): hv.ps1 logs ..., log retention, daily maintenance.
# Log tree under HV_LOG_DIR: homevault\hv-YYYY-MM-DD.log, backup\backup-*.log, nextcloud\{nextcloud,audit}.log,
# caddy\access.log, containers\<service>-YYYY-MM-DD.log, panel\panel.log. Pure helpers are unit-tested (tests/pwsh/unit-ux.ps1).

# Compose services whose container output can be shown (Windows: no wg-easy / scrutiny).
$script:HvLogServices = @('app', 'cron', 'db', 'redis', 'caddy', 'panel', 'socket-proxy', 'ddns-go')
$script:HvDefaultLogLines = 200

# ---------------------------------------------------------------- pure helpers

function ConvertTo-HvRetentionDays {
    # Pure: log retention in days, an integer 1-365 (digits only); throws a Chinese message otherwise.
    param([AllowNull()]$Value)
    $t = ([string](ConvertTo-HvArgString $Value)).Trim()
    if ($t -notmatch '^[0-9]{1,3}$' -or [int]$t -lt 1 -or [int]$t -gt 365) {
        throw ('日志保留天数必须是 1 到 365 之间的整数（当前输入：' + $t + '）。')
    }
    return [int]$t
}

function Get-HvLogRetentionDays {
    # HV_LOG_RETENTION_DAYS of the given (or loaded) .env; 7 when missing or invalid.
    param([System.Collections.IDictionary]$Env = $null)
    if ($null -eq $Env) { $Env = Get-HvEnv }
    try { return (ConvertTo-HvRetentionDays (Get-HvEnvDictValue $Env 'HV_LOG_RETENTION_DAYS' '7')) } catch { return 7 }
}

function Test-HvManagedLogName {
    # Pure: file names the retention job may delete (*.log, *.log.*, *.gz, *.txt), as on Linux.
    param([AllowEmptyString()][string]$Name)
    return ($Name -match '(?i)(\.log|\.gz|\.txt)$' -or $Name -match '(?i)\.log\.')
}

function Select-HvExpiredLogFiles {
    # Pure: the files (objects with Name and LastWriteTime) last written more than $Days days before $Now.
    param([object[]]$Files = @(), [int]$Days, [datetime]$Now)
    if ($Days -lt 1) { throw '日志保留天数必须至少为 1 天。' }
    $cut = $Now.AddDays(-$Days)
    $out = New-Object System.Collections.Generic.List[object]
    foreach ($f in @($Files)) {
        if ($null -eq $f) { continue }
        if (-not (Test-HvManagedLogName ([string]$f.Name))) { continue }
        if ([datetime]$f.LastWriteTime -lt $cut) { $out.Add($f) }
    }
    return $out.ToArray()
}

function Resolve-HvLogFilePath {
    # Pure (no file system access): full path of a file below $Dir from a path the user typed relative to it.
    # Rejects absolute paths, drive letters, '..', alternate data streams and hidden (dot) names.
    param([string]$Dir, [AllowEmptyString()][string]$Relative)
    $r = ([string]$Relative).Trim()
    if ($r -eq '') { throw '请指定日志文件（相对日志目录的路径，例如 caddy\access.log）。' }
    $bad = ('只能查看日志目录内的文件：' + $r)
    if ($r -match '^[\\/]' -or $r.Contains(':')) { throw $bad }
    $segs = @(($r -split '[\\/]+') | Where-Object { $_ -ne '' -and $_ -ne '.' })
    if ($segs.Count -eq 0) { throw $bad }
    foreach ($s in $segs) { if ($s.StartsWith('.') -or $s.Trim() -ne $s) { throw $bad } }
    $sep = '/'
    if ($Dir.Contains('\') -or $Dir -match '^[A-Za-z]:') { $sep = '\' }
    $base = $Dir
    if ($base.Length -gt 1) { $base = $base.TrimEnd('\', '/') }
    return ($base + $sep + ($segs -join $sep))
}

function Get-HvLogAliasTarget {
    # Pure: friendly names for common log files -> relative path, or 'newest:<dir>|<wildcard>' for the latest file.
    param([AllowEmptyString()][string]$Name)
    switch (([string]$Name).Trim().ToLowerInvariant()) {
        'nextcloud' { return 'nextcloud\nextcloud.log' }
        'audit' { return 'nextcloud\audit.log' }
        'access' { return 'caddy\access.log' }
        'backup' { return 'newest:backup|backup-*.log' }
        'hv' { return 'newest:homevault|hv-*.log' }
        'homevault' { return 'newest:homevault|hv-*.log' }
    }
    return ''
}

function Format-HvLocalTime {
    # Pure: a time from a JSON document as local 'yyyy-MM-dd HH:mm:ss' (PowerShell 7's ConvertFrom-Json already
    # returns [datetime] for ISO strings, 5.1 returns the string); anything unparsable is returned as text.
    param([AllowNull()]$Value)
    $inv = [System.Globalization.CultureInfo]::InvariantCulture
    if ($null -eq $Value) { return '' }
    if ($Value -is [datetime]) { return $Value.ToString('yyyy-MM-dd HH:mm:ss', $inv) }
    if ($Value -is [System.DateTimeOffset]) { return $Value.ToLocalTime().ToString('yyyy-MM-dd HH:mm:ss', $inv) }
    $s = [string]$Value
    $dto = [System.DateTimeOffset]::MinValue
    if ($s -match '^[0-9]{4}-[0-9]{2}-[0-9]{2}[T ][0-9]{2}:[0-9]{2}' -and
        [System.DateTimeOffset]::TryParse($s, $inv, [System.Globalization.DateTimeStyles]::AssumeLocal, [ref]$dto)) {
        return $dto.ToLocalTime().ToString('yyyy-MM-dd HH:mm:ss', $inv)
    }
    return $s
}

function Format-HvLogLine {
    # Pure: make JSON log lines readable (Nextcloud nextcloud.log / audit.log, Caddy access log); other lines unchanged.
    param([AllowEmptyString()][AllowNull()][string]$Line)
    $t = ([string]$Line).Trim()
    if (-not ($t.StartsWith('{') -and $t.EndsWith('}'))) { return [string]$Line }
    $j = $null
    try { $j = ConvertFrom-Json -InputObject $t } catch { return [string]$Line }
    if ($null -eq $j -or $j -isnot [System.Management.Automation.PSCustomObject]) { return [string]$Line }
    $msg = Get-HvPropValue $j 'message'
    $level = Get-HvPropValue $j 'level'
    if ($null -ne $msg -and $null -ne $level -and ($null -ne (Get-HvPropValue $j 'reqId') -or $null -ne (Get-HvPropValue $j 'app'))) {
        $lv = [string]$level
        $names = @{ '0' = '调试'; '1' = '信息'; '2' = '警告'; '3' = '错误'; '4' = '严重' }
        if ($names.ContainsKey($lv)) { $lv = $names[$lv] }
        $m = $msg
        if ($m -isnot [string]) { $m = ConvertTo-HvJson -Value $m -Indent '' }
        $ex = Get-HvPropValue $j 'exception'
        if ($null -ne $ex -and $ex -isnot [string]) {
            $exMsg = [string](Get-HvPropValue $ex 'Message' '')
            $exCls = [string](Get-HvPropValue $ex 'Exception' '')
            if ($exMsg -and $exMsg -ne $m) { $m = $m + ' — ' + $exCls + ': ' + $exMsg }
        }
        $s = (Format-HvLocalTime (Get-HvPropValue $j 'time' '')) + ' [' + $lv + '] ' + [string](Get-HvPropValue $j 'app' '') + ': ' + $m
        $extra = @()
        $user = [string](Get-HvPropValue $j 'user' '')
        if ($user -and $user -ne '--') { $extra += ('用户 ' + $user) }
        $ip = [string](Get-HvPropValue $j 'remoteAddr' '')
        if ($ip) { $extra += ('IP ' + $ip) }
        if ($extra.Count -gt 0) { $s += '（' + ($extra -join '，') + '）' }
        return $s
    }
    $req = Get-HvPropValue $j 'request'
    $status = Get-HvPropValue $j 'status'
    if ($null -ne $req -and $null -ne $status) {
        $inv = [System.Globalization.CultureInfo]::InvariantCulture
        $ts = Get-HvPropValue $j 'ts'
        $time = [string]$ts
        $tsNum = 0.0
        if ($null -ne $ts -and [double]::TryParse([string]$ts, [System.Globalization.NumberStyles]::Float, $inv, [ref]$tsNum) -and $tsNum -gt 0) {
            $time = [System.DateTimeOffset]::FromUnixTimeMilliseconds([long]($tsNum * 1000)).ToLocalTime().ToString('yyyy-MM-dd HH:mm:ss', $inv)
        }
        $ip = [string](Get-HvPropValue $req 'client_ip' '')
        if (-not $ip) { $ip = [string](Get-HvPropValue $req 'remote_ip' '') }
        $s = $time + ' ' + [string]$status + ' ' + [string](Get-HvPropValue $req 'method' '') + ' ' +
            [string](Get-HvPropValue $req 'host' '') + [string](Get-HvPropValue $req 'uri' '') + ' ' + $ip
        $dur = 0.0
        if ([double]::TryParse([string](Get-HvPropValue $j 'duration' ''), [System.Globalization.NumberStyles]::Float, $inv, [ref]$dur)) {
            $s += ' ' + [string][long][Math]::Round($dur * 1000) + 'ms'
        }
        $size = 0.0
        if ([double]::TryParse([string](Get-HvPropValue $j 'size' ''), [System.Globalization.NumberStyles]::Float, $inv, [ref]$size)) {
            $s += ' ' + (ConvertTo-HvSizeText $size)
        }
        return $s
    }
    return [string]$Line
}

function Get-HvRotatedLogName {
    # Pure: nextcloud.log -> nextcloud-2026-09-25.log (nextcloud-2026-09-25.2.log, .3 ... if already taken).
    param([string]$FileName, [string]$Stamp, [string[]]$Existing = @())
    $base = [System.IO.Path]::GetFileNameWithoutExtension($FileName)
    $ext = [System.IO.Path]::GetExtension($FileName)
    $cand = $base + '-' + $Stamp + $ext
    $i = 2
    while (@($Existing) -contains $cand) { $cand = $base + '-' + $Stamp + '.' + $i + $ext; $i++ }
    return $cand
}

function Test-HvLogNeedsRotate {
    # Pure: rotate a non-empty log by date when it was started (created) or last written before today.
    # (An active log is written every day, so its creation time is what shows it spans more than one day.)
    param([long]$Length, [datetime]$CreationTime, [datetime]$LastWriteTime, [datetime]$Now)
    if ($Length -le 0) { return $false }
    return ($CreationTime.Date -lt $Now.Date -or $LastWriteTime.Date -lt $Now.Date)
}

function Get-HvContainerLogRange {
    # Pure: yesterday (local time) as a date stamp and unix-second bounds for `docker compose logs --since/--until`.
    param([datetime]$Now)
    $today = $Now.Date
    $y = $today.AddDays(-1)
    $since = (New-Object System.DateTimeOffset -ArgumentList $y).ToUnixTimeSeconds()
    $until = (New-Object System.DateTimeOffset -ArgumentList $today).ToUnixTimeSeconds()
    return [pscustomobject]@{
        Day   = $y.ToString('yyyy-MM-dd', [System.Globalization.CultureInfo]::InvariantCulture)
        Since = [string]$since
        Until = [string]$until
    }
}

# ---------------------------------------------------------------- files

function Get-HvLogDir {
    # Host log directory: HV_LOG_DIR, else <HV_DATA_DIR>\logs (native separators on Windows).
    $e = Get-HvEnv
    $d = Get-HvEnvDictValue $e 'HV_LOG_DIR'
    if (-not $d -and (Get-Command Get-HvDefaultLogDir -ErrorAction SilentlyContinue)) { $d = Get-HvDefaultLogDir $e }
    if (-not $d) {
        $b = Get-HvEnvDictValue $e 'HV_DATA_DIR'
        if ($b) { $d = Join-HvPath $b 'logs' }
    }
    if (-not $d) { Stop-Hv '未设置日志目录 HV_LOG_DIR：请重新运行 install（或 up）。' }
    if (Test-HvWindows) { $d = $d -replace '/', '\' }
    if ($d.Length -gt 3) { $d = $d.TrimEnd('\', '/') }
    return $d
}

function Initialize-HvLogTree {
    # Create HV_LOG_DIR and its subdirectories (shared list from env.ps1 when available).
    $dir = New-HvDirectory (Get-HvLogDir)
    $subs = @('homevault', 'backup', 'nextcloud', 'caddy', 'containers', 'panel')
    if (Get-Command Get-HvLogSubdirs -ErrorAction SilentlyContinue) { $subs = @(Get-HvLogSubdirs) }
    foreach ($s in $subs) { [void](New-HvDirectory (Join-HvPath $dir $s)) }
    return $dir
}

function Start-HvUxLog {
    # Log this command to <HV_LOG_DIR>\homevault\hv-YYYY-MM-DD.log (common.ps1 Start-HvCliLog) unless already logging.
    param([string]$CommandText = '')
    if ($script:HvLogFile) { return }
    if (-not (Test-HvEnvExists)) { return }
    try {
        $dir = Get-HvLogDir
        if (Get-Command Start-HvCliLog -ErrorAction SilentlyContinue) { Start-HvCliLog -LogDir $dir -CommandText $CommandText }
    } catch { }
}

function Get-HvLogFileList {
    # Managed log files below $Dir as FileInfo objects. Reparse points (symlinks/junctions) are never followed.
    param([string]$Dir, [int]$MaxDepth = 6)
    $out = New-Object System.Collections.Generic.List[object]
    if (-not $Dir -or -not [System.IO.Directory]::Exists($Dir)) { return $out.ToArray() }
    $stack = New-Object System.Collections.Generic.Stack[object]
    $stack.Push([pscustomobject]@{ Dir = (New-Object System.IO.DirectoryInfo($Dir)); Depth = 0 })
    while ($stack.Count -gt 0) {
        $cur = $stack.Pop()
        $entries = @()
        try { $entries = @($cur.Dir.GetFileSystemInfos()) } catch { continue }
        foreach ($e in $entries) {
            if (($e.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) { continue }
            if ($e -is [System.IO.DirectoryInfo]) {
                if ($cur.Depth -lt $MaxDepth) { $stack.Push([pscustomobject]@{ Dir = $e; Depth = ($cur.Depth + 1) }) }
            } elseif (Test-HvManagedLogName $e.Name) {
                $out.Add($e)
            }
        }
    }
    return $out.ToArray()
}

function Get-HvRelativeLogPath {
    param([string]$Dir, [string]$FullName)
    $base = (New-Object System.IO.DirectoryInfo($Dir)).FullName.TrimEnd('\', '/')
    if ($FullName.StartsWith($base, [System.StringComparison]::OrdinalIgnoreCase)) { return $FullName.Substring($base.Length).TrimStart('\', '/') }
    return $FullName
}

function Get-HvFileTail {
    # Last N lines of a text file (.gz is decompressed). Plain files are read backwards from the end, so large
    # logs stay cheap; files that are still being written (shared read/write/delete) are fine.
    param([Parameter(Mandatory = $true)][string]$Path, [int]$Lines = 200, [long]$MaxBytes = 16MB)
    if ($Lines -lt 1) { $Lines = 1 }
    $utf8 = New-Object System.Text.UTF8Encoding($false)
    $share = [System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete
    $fs = New-Object System.IO.FileStream($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, $share)
    try {
        if ($Path -match '(?i)\.gz$') {
            $gz = New-Object System.IO.Compression.GZipStream($fs, [System.IO.Compression.CompressionMode]::Decompress)
            $sr = New-Object System.IO.StreamReader($gz, $utf8)
            $q = New-Object 'System.Collections.Generic.Queue[string]'
            try {
                while ($null -ne ($l = $sr.ReadLine())) {
                    $q.Enqueue($l)
                    if ($q.Count -gt $Lines) { [void]$q.Dequeue() }
                }
            } finally { $sr.Dispose() }
            return $q.ToArray()
        }
        $len = $fs.Length
        if ($len -le 0) { return @() }
        $block = 65536
        $pos = $len
        $chunks = New-Object System.Collections.Generic.List[byte[]]
        $newlines = 0
        $total = [long]0
        while ($pos -gt 0 -and $newlines -le $Lines -and $total -lt $MaxBytes) {
            $size = [int][Math]::Min([long]$block, $pos)
            $pos -= $size
            $buf = New-Object byte[] $size
            [void]$fs.Seek($pos, [System.IO.SeekOrigin]::Begin)
            $read = 0
            while ($read -lt $size) {
                $r = $fs.Read($buf, $read, $size - $read)
                if ($r -le 0) { break }
                $read += $r
            }
            $i = [Array]::IndexOf($buf, [byte]10, 0)
            while ($i -ge 0) {
                $newlines++
                if ($i + 1 -ge $size) { break }
                $i = [Array]::IndexOf($buf, [byte]10, $i + 1)
            }
            $chunks.Insert(0, $buf)
            $total += $size
        }
        $all = New-Object byte[] $total
        $off = 0
        foreach ($c in $chunks) { [System.Array]::Copy($c, 0, $all, $off, $c.Length); $off += $c.Length }
        $text = $utf8.GetString($all)
        $parts = @($text -split "`n")
        if ($parts.Count -gt 0 -and $parts[$parts.Count - 1] -eq '') { $parts = @($parts | Select-Object -First ($parts.Count - 1)) }
        if ($pos -gt 0 -and $parts.Count -gt 0) { $parts = @($parts | Select-Object -Skip 1) }  # first line may be partial
        $res = @($parts | Select-Object -Last $Lines)
        for ($k = 0; $k -lt $res.Count; $k++) { $res[$k] = ([string]$res[$k]).TrimEnd("`r") }
        return $res
    } finally {
        $fs.Dispose()
    }
}

# ---------------------------------------------------------------- hv.ps1 logs ...

function Get-HvNewestLogFile {
    param([string]$Dir, [string]$Wildcard)
    if (-not [System.IO.Directory]::Exists($Dir)) { return $null }
    $f = @(Get-ChildItem -LiteralPath $Dir -File -Filter $Wildcard -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1)
    if ($f.Count -eq 0) { return $null }
    return $f[0]
}

function Show-HvLogList {
    $dir = Get-HvLogDir
    $days = Get-HvLogRetentionDays
    Write-HvStep ('日志目录：' + $dir + '（保留 ' + $days + ' 天，每天 04:00 自动清理）')
    $files = @(Get-HvLogFileList $dir | Sort-Object LastWriteTime -Descending)
    if ($files.Count -eq 0) {
        Write-HvInfo '（还没有日志文件）'
    } else {
        $rows = @()
        foreach ($f in @($files | Select-Object -First 200)) {
            $rows += [pscustomobject]@{
                T = $f.LastWriteTime.ToString('yyyy-MM-dd HH:mm', [System.Globalization.CultureInfo]::InvariantCulture)
                S = (ConvertTo-HvSizeText $f.Length)
                P = (Get-HvRelativeLogPath -Dir $dir -FullName $f.FullName)
            }
        }
        foreach ($l in (Format-HvTable -Rows $rows -Columns @('T', 'S', 'P') -Headers @('修改时间', '大小', '文件'))) { Write-Host ('  ' + $l) }
        if ($files.Count -gt 200) { Write-HvInfo ('……共 ' + $files.Count + ' 个文件，只显示最新的 200 个。') }
    }
    Write-HvInfo ('容器输出：' + ($script:HvLogServices -join ' '))
    Write-HvInfo '查看：logs show <文件|服务|nextcloud|audit|access|backup|hv> [--lines 200]    实时跟踪：logs <服务> follow'
}

function Show-HvLogTarget {
    # A compose service -> its container output; otherwise a file below HV_LOG_DIR (aliases: nextcloud, audit, access, backup, hv).
    param([string]$Target, [int]$Lines = 200, [switch]$Raw)
    $t = ([string]$Target).Trim()
    if ($script:HvLogServices -contains $t) {
        Assert-HvDockerQuick
        Write-HvInfo ('== 容器 ' + $t + ' 的输出（最后 ' + $Lines + ' 行）')
        [void](Invoke-HvCompose -Arguments @('logs', '--no-color', '--timestamps', '--tail', [string]$Lines, $t) -AllowFailure)
        return
    }
    $dir = Get-HvLogDir
    $rel = Get-HvLogAliasTarget $t
    $full = ''
    if ($rel -like 'newest:*') {
        $spec = $rel.Substring(7) -split '\|'
        $newest = Get-HvNewestLogFile -Dir (Join-HvPath $dir $spec[0]) -Wildcard $spec[1]
        if ($null -eq $newest) { Stop-Hv ('还没有这类日志：' + $t + '（' + (Join-HvPath $dir $spec[0]) + '）') 2 }
        $full = $newest.FullName
    } else {
        if (-not $rel) { $rel = $t }
        try { $full = Resolve-HvLogFilePath -Dir $dir -Relative $rel } catch { Stop-Hv $_.Exception.Message 2 }
    }
    if (-not [System.IO.File]::Exists($full)) {
        Stop-Hv ('找不到日志：' + $t + '（运行 logs list 查看全部日志文件；容器输出可用：' + ($script:HvLogServices -join ' ') + '）') 2
    }
    $fi = New-Object System.IO.FileInfo($full)
    if (($fi.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) { Stop-Hv ('不支持符号链接：' + $full) 2 }
    Write-HvInfo ('== ' + $full + '（最后 ' + $Lines + ' 行，' + (ConvertTo-HvSizeText $fi.Length) + '）')
    foreach ($l in @(Get-HvFileTail -Path $full -Lines $Lines)) {
        if ($Raw) { Write-Host $l } else { Write-Host (Format-HvLogLine $l) }
    }
}

function Invoke-HvLogClean {
    # Delete managed log files older than the retention (default: HV_LOG_RETENTION_DAYS). Returns the count.
    param([int]$Days = 0)
    if ($Days -lt 1) { $Days = Get-HvLogRetentionDays }
    $dir = Get-HvLogDir
    $expired = @(Select-HvExpiredLogFiles -Files (Get-HvLogFileList $dir) -Days $Days -Now (Get-Date))
    $n = 0
    $failed = @()
    foreach ($f in $expired) {
        try {
            if ($f.IsReadOnly) { $f.IsReadOnly = $false }
            [System.IO.File]::Delete($f.FullName)
            $n++
        } catch { $failed += (Get-HvRelativeLogPath -Dir $dir -FullName $f.FullName) }
    }
    Write-HvOk ('已清理 ' + $n + ' 个超过 ' + $Days + ' 天的日志文件（' + $dir + '）。')
    if ($failed.Count -gt 0) { Write-HvWarn ('有 ' + $failed.Count + ' 个文件无法删除（可能正在使用）：' + (($failed | Select-Object -First 5) -join '，')) }
    return $n
}

function Open-HvLogDir {
    $dir = Get-HvLogDir
    [void](New-HvDirectory $dir)
    Write-HvInfo ('日志目录：' + $dir)
    if (Test-HvWindows) {
        # explorer hands the window to the (non-elevated) desktop shell
        Start-Process -FilePath 'explorer.exe' -ArgumentList ('"' + $dir + '"')
    }
}

function Update-HvCaddyLogRetention {
    # Caddy reads {$HV_LOG_RETENTION_DAYS} from its container environment, which only changes when the container
    # is recreated (a USR1 reload would re-read the Caddyfile with the old value): `up -d --no-deps caddy`.
    if (-not (Get-Command docker -ErrorAction SilentlyContinue)) { Write-HvInfo 'Docker 未就绪：Caddy 访问日志的新保留天数将在下次启动时生效。'; return }
    $row = Get-HvServiceState -Rows (Get-HvComposePs) -Service 'caddy'
    if ($null -eq $row -or $row.State -ne 'running') { Write-HvInfo 'caddy 未运行：新的保留天数将在下次启动时生效。'; return }
    $r = Invoke-HvCompose -Arguments @('up', '-d', '--no-deps', 'caddy') -Capture -AllowFailure
    if ($r.ExitCode -eq 0) { Write-HvOk 'Caddy 已按新的保留天数重建（访问日志滚动文件按新天数保留）。' }
    else { Write-HvWarn ('重建 caddy 失败（退出码 ' + $r.ExitCode + '）：新的保留天数将在下次 up 时生效。') }
}

function Set-HvLogRetention {
    # Write HV_LOG_RETENTION_DAYS to .env, refresh state/status.json (the panel shows it) and apply it to Caddy.
    param([Parameter(Mandatory = $true)]$Days, [switch]$SkipCaddy)
    $d = ConvertTo-HvRetentionDays $Days
    Update-HvEnv ([ordered]@{ HV_LOG_RETENTION_DAYS = [string]$d })
    Write-HvOk ('日志保留天数已设为 ' + $d + ' 天（每天 04:00 的维护任务删除更早的日志）。')
    try { Update-HvStatusFile } catch { Write-HvWarn ('更新 state\status.json 失败：' + (Get-HvErrorMessage $_)) }
    if (-not $SkipCaddy) { Update-HvCaddyLogRetention }
    return $d
}

function Get-HvLogLinesOption {
    param([hashtable]$Parsed)
    $v = Get-HvOpt $Parsed 'lines' ''
    if (-not $v) { $v = Get-HvOpt $Parsed 'n' '' }
    if (-not $v) { $v = Get-HvOpt $Parsed 'tail' '' }
    if (-not $v) { return $script:HvDefaultLogLines }
    $n = 0
    if (-not [int]::TryParse([string]$v, [ref]$n) -or $n -lt 1 -or $n -gt 100000) { Stop-Hv ('--lines 必须是 1 到 100000 之间的数字：' + $v) 2 }
    return $n
}

function Show-HvLogsHelp {
    Write-Host @'
用法：.\windows\hv.ps1 logs <子命令>
  logs list                          列出日志目录里的全部日志文件
  logs show <文件|服务> [--lines N]  查看最后 N 行（默认 200；文件为相对日志目录的路径）
        快捷名：nextcloud（Nextcloud 日志）audit（审计日志）access（访问日志）backup（最近一次备份）hv（本工具操作日志）
        服务：app cron db redis caddy panel socket-proxy ddns-go（容器输出）   --raw 显示原始 JSON
  logs open                          在资源管理器中打开日志文件夹
  logs retention [天数]              查看或设置日志保留天数（1-365，默认 7）
  logs clean                         立即删除超过保留天数的日志
  logs [服务...] [follow] [--tail N] 容器输出；follow 实时跟踪（Ctrl+C 结束）
'@
}

function Invoke-HvLogs {
    # hv.ps1 logs list | show <文件|服务> [--lines N] [--raw] | open | retention [天数] | clean | [服务...] [follow|--follow] [--tail N]
    param([Parameter(ValueFromRemainingArguments = $true)][object[]]$Arguments = @())
    $p = Read-HvCommandArgs -Arguments $Arguments -Switches @('follow', 'f', 'raw') -Options @('lines', 'n', 'tail')
    if (Test-HvOpt $p 'help') { Show-HvLogsHelp; return }
    [void](Get-HvEnv)
    $pos = @($p.Positional)
    $sub = ''
    if ($pos.Count -gt 0) { $sub = $pos[0].ToLowerInvariant() }
    $rest = @()
    if ($pos.Count -gt 1) { $rest = @($pos[1..($pos.Count - 1)]) }
    $lines = Get-HvLogLinesOption $p
    switch ($sub) {
        'help' { Show-HvLogsHelp; return }
        'list' { Show-HvLogList; return }
        'show' {
            if ($rest.Count -eq 0) { Stop-Hv '用法：logs show <文件|服务> [--lines N]（先运行 logs list 查看有哪些日志）' 2 }
            foreach ($t in $rest) { Show-HvLogTarget -Target $t -Lines $lines -Raw:(Test-HvOpt $p 'raw') }
            return
        }
        'open' { Open-HvLogDir; return }
        'retention' {
            if ($rest.Count -eq 0) {
                Write-HvInfo ('当前日志保留天数：' + (Get-HvLogRetentionDays) + ' 天（修改：logs retention <1-365>）')
                return
            }
            $d = 0
            try { $d = ConvertTo-HvRetentionDays $rest[0] } catch { Stop-Hv $_.Exception.Message 2 }
            Start-HvUxLog ('logs retention ' + $d)
            [void](Set-HvLogRetention -Days $d)
            return
        }
        'clean' {
            Start-HvUxLog 'logs clean'
            [void](Invoke-HvLogClean)
            return
        }
    }
    # container output: logs [服务...] [follow]; like the Linux CLI it follows by default in an interactive window
    $follow = (Test-HvOpt $p 'follow') -or (Test-HvOpt $p 'f')
    if (-not $follow -and -not $p.Opts.ContainsKey('follow') -and (Test-HvInteractive)) {
        $redirected = $true
        try { $redirected = [System.Console]::IsOutputRedirected } catch { }
        if (-not $redirected) { $follow = $true }
    }
    $svcs = @()
    foreach ($x in $pos) {
        if (@('follow', '-f') -contains $x.ToLowerInvariant()) { $follow = $true } else { $svcs += $x }
    }
    Assert-HvDockerQuick
    $a = @('logs', '--tail', [string]$lines)
    if ($follow) { $a += '-f' }
    $a += $svcs
    [void](Invoke-HvCompose -Arguments $a -AllowFailure)
}

# ---------------------------------------------------------------- daily maintenance (hv.ps1 maintenance)

function Test-HvDockerAvailable {
    if (-not (Get-Command docker -ErrorAction SilentlyContinue)) { return $false }
    try { return [bool](Get-HvDockerInfo).Ok } catch { return $false }
}

function Export-HvContainerLogs {
    # Yesterday's output of every container of the project -> <HV_LOG_DIR>\containers\<service>-YYYY-MM-DD.log.
    # Existing non-empty files are kept (the job may run twice). Returns the number of files written.
    param([datetime]$Now = (Get-Date))
    $dir = New-HvDirectory (Join-HvPath (Get-HvLogDir) 'containers')
    $range = Get-HvContainerLogRange -Now $Now
    $services = New-Object System.Collections.Generic.List[string]
    foreach ($r in @(Get-HvComposePs)) {
        $s = [string](Get-HvPropValue $r 'Service' '')
        if ($s -and $s -match '^[A-Za-z0-9_.-]+$' -and -not $services.Contains($s)) { $services.Add($s) }
    }
    $n = 0
    foreach ($svc in $services) {
        $out = Join-HvPath $dir ($svc + '-' + $range.Day + '.log')
        if ([System.IO.File]::Exists($out) -and (New-Object System.IO.FileInfo($out)).Length -gt 0) { continue }
        $a = @(Get-HvComposeArgs) + @('logs', '--no-color', '--timestamps', '--since', $range.Since, '--until', $range.Until, $svc)
        $code = 1
        try { $code = Invoke-HvNativeToFile -FilePath 'docker' -ArgumentList $a -OutFile $out } catch { $code = 1 }
        $len = 0
        if ([System.IO.File]::Exists($out)) { $len = (New-Object System.IO.FileInfo($out)).Length }
        if ($code -ne 0 -or $len -eq 0) { Remove-Item -LiteralPath $out -Force -ErrorAction SilentlyContinue } else { $n++ }
    }
    return $n
}

function Invoke-HvNextcloudLogRotate {
    # nextcloud.log / audit.log -> <name>-<yesterday>.log once they span more than one day (Nextcloud re-creates them).
    param([datetime]$Now = (Get-Date))
    $dir = Join-HvPath (Get-HvLogDir) 'nextcloud'
    $done = @()
    if (-not [System.IO.Directory]::Exists($dir)) { return $done }
    $stamp = $Now.Date.AddDays(-1).ToString('yyyy-MM-dd', [System.Globalization.CultureInfo]::InvariantCulture)
    $existing = @(Get-ChildItem -LiteralPath $dir -File -ErrorAction SilentlyContinue | ForEach-Object { $_.Name })
    foreach ($name in @('nextcloud.log', 'audit.log')) {
        $path = Join-HvPath $dir $name
        if (-not [System.IO.File]::Exists($path)) { continue }
        $fi = New-Object System.IO.FileInfo($path)
        if (-not (Test-HvLogNeedsRotate -Length $fi.Length -CreationTime $fi.CreationTime -LastWriteTime $fi.LastWriteTime -Now $Now)) { continue }
        $target = Get-HvRotatedLogName -FileName $name -Stamp $stamp -Existing $existing
        try {
            [System.IO.File]::Move($path, (Join-HvPath $dir $target))
            $existing += $target
            $done += $target
        } catch { Write-HvWarn ('无法轮转 ' + $path + '：' + $_.Exception.Message) }
    }
    return $done
}

function Copy-HvCaToState {
    # state\ca.crt for the panel's /ca.crt download (root certificate only): IP mode copies Caddy's local root CA,
    # domain mode (acme-dns) removes a stale copy. Returns the path or ''.
    $state = New-HvDirectory (Get-HvPath 'state')
    $dst = Join-HvPath $state 'ca.crt'
    if ((Get-HvEnvValue 'HV_TLS_MODE' 'internal') -ne 'internal') {
        if ([System.IO.File]::Exists($dst)) { Remove-Item -LiteralPath $dst -Force -ErrorAction SilentlyContinue }
        return ''
    }
    $tmp = New-HvTempPath $dst
    try {
        $p = Export-HvCa -Path $tmp
        if (-not $p -or -not [System.IO.File]::Exists($tmp)) { return '' }
        $txt = Read-HvTextFile $tmp
        if ($txt -notmatch '-----BEGIN CERTIFICATE-----' -or $txt -match 'PRIVATE KEY') { return '' }
        Move-HvFileReplace -Source $tmp -Destination $dst
        return $dst
    } finally {
        if ([System.IO.File]::Exists($tmp)) { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
    }
}

function Invoke-HvMaintenance {
    # Daily job (task HomeVault-Maintenance, 04:00): export yesterday's container logs, rotate nextcloud.log/audit.log,
    # delete logs older than HV_LOG_RETENTION_DAYS, refresh state\ca.crt, write state\status.json (+ vpn-status.json).
    param([Parameter(ValueFromRemainingArguments = $true)][object[]]$Arguments = @())
    [void](Read-HvCommandArgs -Arguments $Arguments)
    [void](Get-HvEnv)
    $problems = @()
    $notes = @()
    try { [void](Initialize-HvLogTree) } catch { $problems += ('无法创建日志目录：' + (Get-HvErrorMessage $_)) }
    Start-HvUxLog 'maintenance'
    Write-HvStep ('HomeVault 每日维护：' + (Get-Date).ToString('yyyy-MM-dd HH:mm:ss', [System.Globalization.CultureInfo]::InvariantCulture))
    $docker = Test-HvDockerAvailable
    if ($docker) {
        try { $n = Export-HvContainerLogs; $notes += ('导出容器日志 ' + $n + ' 个') } catch { $problems += ('导出容器日志失败：' + (Get-HvErrorMessage $_)) }
    } else {
        $problems += 'Docker 未运行，未导出容器日志'
    }
    try {
        $rot = @(Invoke-HvNextcloudLogRotate)
        if ($rot.Count -gt 0) { $notes += ('轮转 ' + ($rot -join '、')) }
    } catch { $problems += ('轮转 Nextcloud 日志失败：' + (Get-HvErrorMessage $_)) }
    try { $c = Invoke-HvLogClean; $notes += ('清理过期日志 ' + $c + ' 个') } catch { $problems += ('清理日志失败：' + (Get-HvErrorMessage $_)) }
    if ($docker) { try { [void](Copy-HvCaToState) } catch { } }
    $ok = ($problems.Count -eq 0)
    $message = '每日维护完成'
    if ($notes.Count -gt 0) { $message += '（' + ($notes -join '，') + '）' }
    if (-not $ok) { $message += '；问题：' + ($problems -join '；') }
    try { Update-HvStatusFile -Maintenance @{ ok = $ok; message = $message } -IncludeDisks } catch { Write-HvWarn ('写入 state\status.json 失败：' + (Get-HvErrorMessage $_)) }
    try { [void](Update-HvVpnStatusFile) } catch { }
    if ($ok) { Write-HvOk $message } else { Stop-Hv $message 1 }
}
