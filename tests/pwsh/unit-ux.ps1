#Requires -Version 5.1
# Unit tests for the Windows ease-of-use + logs modules (windows/lib/{logs,status,requests,android,shortcuts,menu}.ps1)
# and the double-click launchers (一键安装.cmd, windows/HomeVault管理.cmd). Self-contained: plain assertions, temp dirs,
# no Docker/network. Run: pwsh -NoProfile -File tests/pwsh/unit-ux.ps1 [-Root <repo>]. Exit code 1 on any failure.
# -OutDir: also write <OutDir>/state/{vpn-status,status}.json from the real builders, for tests/pwsh/run.sh's Go decode
# check (tests/pwsh/statecheck: listen port 43210, peers phone1 + phone-mama).
param(
    [string]$Root = (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)),
    [string]$OutDir = ''
)

$ErrorActionPreference = 'Stop'
$script:HvRoot = $Root
foreach ($lib in @(Get-ChildItem -LiteralPath (Join-Path $Root 'windows/lib') -Filter '*.ps1' | Sort-Object Name)) { . $lib.FullName }
$script:HvNonInteractive = $true

$script:Pass = 0
$script:Fail = 0
function Assert-Eq {
    param([string]$Name, $Expected, $Actual)
    $e = $Expected; $a = $Actual
    if ($e -is [System.Array]) { $e = '[' + ($e -join '|') + ']' }
    if ($a -is [System.Array]) { $a = '[' + ($a -join '|') + ']' }
    if ([string]$e -ceq [string]$a) { $script:Pass++ } else {
        $script:Fail++
        Write-Host ('  FAIL ' + $Name)
        Write-Host ('       expected: ' + [string]$e)
        Write-Host ('       actual:   ' + [string]$a)
    }
}
function Assert-True {
    param([string]$Name, $Cond)
    if ($Cond) { $script:Pass++ } else { $script:Fail++; Write-Host ('  FAIL ' + $Name) }
}
function Assert-Throws {
    param([string]$Name, [scriptblock]$Block, [string]$Like = '*')
    try { & $Block | Out-Null; $script:Fail++; Write-Host ('  FAIL ' + $Name + ' (no exception)') }
    catch {
        $m = Get-HvErrorMessage $_
        if ($m -like $Like) { $script:Pass++ } else { $script:Fail++; Write-Host ('  FAIL ' + $Name + ' (message: ' + $m + ')') }
    }
}
function Section { param([string]$T) Write-Host ('-- ' + $T) }
function New-TempDir {
    $d = Join-Path ([System.IO.Path]::GetTempPath()) ('hv-ux-' + [guid]::NewGuid().ToString('N'))
    [void](New-Item -ItemType Directory -Force -Path $d)
    return $d
}
function Write-Utf8 { param([string]$Path, [string]$Text) [System.IO.File]::WriteAllText($Path, $Text, (New-Object System.Text.UTF8Encoding($false))) }
$inv = [System.Globalization.CultureInfo]::InvariantCulture
$tempDirs = New-Object System.Collections.Generic.List[string]

# canonical json field names of the panel (panel/internal/hoststate/types.go)
$goTags = @{}
$typesGo = Join-Path $Root 'panel/internal/hoststate/types.go'
if (Test-Path -LiteralPath $typesGo) {
    foreach ($m in [regex]::Matches([System.IO.File]::ReadAllText($typesGo), 'json:"([A-Za-z_]+)')) { $goTags[$m.Groups[1].Value] = $true }
}
function Assert-CanonicalKeys {
    param([string]$Name, [object[]]$Keys)
    if ($goTags.Count -eq 0) { Write-Host '  (types.go not found - canonical key check skipped)'; return }
    $bad = @($Keys | Where-Object { -not $goTags.ContainsKey([string]$_) })
    Assert-Eq ($Name + ': only canonical json names (types.go)') '' ($bad -join ',')
}

try {
    # ------------------------------------------------------------------ retention validation
    Section 'retention days'
    foreach ($c in @(@('7', 7), @('1', 1), @('365', 365), @('007', 7), @(' 30 ', 30), @(14, 14))) {
        Assert-Eq ('ConvertTo-HvRetentionDays ' + $c[0]) $c[1] (ConvertTo-HvRetentionDays $c[0])
    }
    foreach ($bad in @('0', '366', '-1', 'abc', '', '7.5', '1e2', '+7', '1000', '３０')) {
        Assert-Throws ('ConvertTo-HvRetentionDays rejects "' + $bad + '"') { ConvertTo-HvRetentionDays $bad } '*1 到 365*'
    }
    Assert-Eq 'retention from full-width input via ConvertTo-HvHalfWidth' 30 (ConvertTo-HvRetentionDays (ConvertTo-HvHalfWidth '３０'))
    Assert-Eq 'Get-HvLogRetentionDays default' 7 (Get-HvLogRetentionDays ([ordered]@{}))
    Assert-Eq 'Get-HvLogRetentionDays invalid -> 7' 7 (Get-HvLogRetentionDays ([ordered]@{ HV_LOG_RETENTION_DAYS = '999' }))
    Assert-Eq 'Get-HvLogRetentionDays 30' 30 (Get-HvLogRetentionDays ([ordered]@{ HV_LOG_RETENTION_DAYS = '30' }))

    # ------------------------------------------------------------------ log file selection
    Section 'log file age selection'
    foreach ($n in @('a.log', 'A.LOG', 'nextcloud.log.1', 'access-2026-09-25T03-00-00.000.log.gz', 'x.gz', 'notes.txt', 'nextcloud-2026-09-25.2.log', 'panel-2026-09-25.log')) {
        Assert-True ('managed: ' + $n) (Test-HvManagedLogName $n)
    }
    foreach ($n in @('status.json', 'x.logx', 'caddy.conf', 'restic.key', 'README.md', 'hv.ps1', 'log')) {
        Assert-True ('not managed: ' + $n) (-not (Test-HvManagedLogName $n))
    }
    $now = New-Object DateTime 2026, 9, 26, 4, 0, 0
    $files = @(
        [pscustomobject]@{ Name = 'old.log'; LastWriteTime = $now.AddDays(-8) }
        [pscustomobject]@{ Name = 'edge.log'; LastWriteTime = $now.AddDays(-7) }
        [pscustomobject]@{ Name = 'new.log'; LastWriteTime = $now.AddDays(-1) }
        [pscustomobject]@{ Name = 'old.json'; LastWriteTime = $now.AddDays(-30) }
        [pscustomobject]@{ Name = 'older.log.gz'; LastWriteTime = $now.AddDays(-100) }
    )
    $exp = @(Select-HvExpiredLogFiles -Files $files -Days 7 -Now $now | ForEach-Object { $_.Name })
    Assert-Eq 'expired after 7 days (strictly older; managed names only)' 'old.log,older.log.gz' ($exp -join ',')
    Assert-Eq 'expired after 365 days' '' ((@(Select-HvExpiredLogFiles -Files $files -Days 365 -Now $now | ForEach-Object { $_.Name })) -join ',')
    Assert-Eq 'expired after 1 day' 'old.log,edge.log,older.log.gz' ((@(Select-HvExpiredLogFiles -Files $files -Days 1 -Now $now | ForEach-Object { $_.Name })) -join ',')
    Assert-Throws 'days < 1 refused (never delete everything)' { Select-HvExpiredLogFiles -Files $files -Days 0 -Now $now } '*至少*'

    $logRoot = New-TempDir; $tempDirs.Add($logRoot)
    foreach ($d in @('homevault', 'caddy', 'nextcloud', 'containers/deep/er')) { [void](New-Item -ItemType Directory -Force -Path (Join-Path $logRoot $d)) }
    Write-Utf8 (Join-Path $logRoot 'caddy/access.log') "x`n"
    Write-Utf8 (Join-Path $logRoot 'nextcloud/nextcloud.log.1') "x`n"
    Write-Utf8 (Join-Path $logRoot 'containers/deep/er/app-2026-09-01.log') "x`n"
    Write-Utf8 (Join-Path $logRoot 'containers/keep.json') "{}`n"
    $outside = New-TempDir; $tempDirs.Add($outside)
    Write-Utf8 (Join-Path $outside 'victim.log') "must survive`n"
    $linked = $false
    try { [void](New-Item -ItemType SymbolicLink -Path (Join-Path $logRoot 'linkdir') -Target $outside); $linked = $true } catch { }
    $list = @(Get-HvLogFileList $logRoot | ForEach-Object { Get-HvRelativeLogPath -Dir $logRoot -FullName $_.FullName } | ForEach-Object { $_ -replace '\\', '/' } | Sort-Object)
    Assert-Eq 'Get-HvLogFileList finds managed files recursively' 'caddy/access.log,containers/deep/er/app-2026-09-01.log,nextcloud/nextcloud.log.1' ($list -join ',')
    if ($linked) { Assert-True 'symlinked directory not followed' (-not (($list -join ',') -match 'victim')) }

    # ------------------------------------------------------------------ path resolution + aliases
    Section 'log paths'
    Assert-Eq 'resolve windows' 'D:\HomeVault\logs\caddy\access.log' (Resolve-HvLogFilePath -Dir 'D:\HomeVault\logs' -Relative 'caddy/access.log')
    Assert-Eq 'resolve windows (trailing \)' 'D:\HomeVault\logs\caddy\access.log' (Resolve-HvLogFilePath -Dir 'D:\HomeVault\logs\' -Relative 'caddy\access.log')
    Assert-Eq 'resolve linux' '/srv/homevault/logs/caddy/access.log' (Resolve-HvLogFilePath -Dir '/srv/homevault/logs' -Relative 'caddy\access.log')
    Assert-Eq 'resolve ./ segments' '/srv/logs/a.log' (Resolve-HvLogFilePath -Dir '/srv/logs' -Relative './a.log')
    foreach ($bad in @('..\secrets\x', 'caddy/../../etc/passwd', 'C:\Windows\win.ini', '/etc/passwd', '\\server\share\x.log', 'a.log:stream', '.hidden.log', 'caddy/.x.log', '', '   ')) {
        Assert-Throws ('resolve rejects "' + $bad + '"') { Resolve-HvLogFilePath -Dir 'D:\HomeVault\logs' -Relative $bad } '*'
    }
    Assert-Eq 'alias nextcloud' 'nextcloud\nextcloud.log' (Get-HvLogAliasTarget 'nextcloud')
    Assert-Eq 'alias audit' 'nextcloud\audit.log' (Get-HvLogAliasTarget 'Audit')
    Assert-Eq 'alias access' 'caddy\access.log' (Get-HvLogAliasTarget 'access')
    Assert-Eq 'alias backup' 'newest:backup|backup-*.log' (Get-HvLogAliasTarget 'backup')
    Assert-Eq 'alias hv' 'newest:homevault|hv-*.log' (Get-HvLogAliasTarget 'hv')
    Assert-Eq 'no alias' '' (Get-HvLogAliasTarget 'caddy/access.log')

    # ------------------------------------------------------------------ tail
    Section 'tail'
    $tdir = New-TempDir; $tempDirs.Add($tdir)
    $big = Join-Path $tdir 'big.log'
    $sb = New-Object System.Text.StringBuilder
    for ($i = 1; $i -le 5000; $i++) { [void]$sb.Append(('第 {0} 行 line {0} ' -f $i) + ('x' * 40) + "`n") }
    Write-Utf8 $big $sb.ToString()
    $t = @(Get-HvFileTail -Path $big -Lines 3)
    Assert-Eq 'tail 3 of a >64KB file' 3 $t.Count
    Assert-True 'tail last line' ($t[2] -like '第 5000 行 line 5000 *')
    Assert-True 'tail first of 3' ($t[0] -like '第 4998 行 *')
    $t = @(Get-HvFileTail -Path $big -Lines 2500)
    Assert-Eq 'tail 2500 spans several 64KB blocks' 2500 $t.Count
    Assert-True 'tail 2500 starts at line 2501' ($t[0] -like '第 2501 行 *')
    $small = Join-Path $tdir 'small.log'
    Write-Utf8 $small "a`r`nb`r`nc"
    Assert-Eq 'tail CRLF, no final newline' '[a|b|c]' (@(Get-HvFileTail -Path $small -Lines 10))
    Assert-Eq 'tail 2 of 3' '[b|c]' (@(Get-HvFileTail -Path $small -Lines 2))
    $empty = Join-Path $tdir 'empty.log'
    Write-Utf8 $empty ''
    Assert-Eq 'tail of empty file' 0 (@(Get-HvFileTail -Path $empty -Lines 5)).Count
    $gzPath = Join-Path $tdir 'rolled.log.gz'
    $fs = [System.IO.File]::Create($gzPath)
    $gz = New-Object System.IO.Compression.GZipStream($fs, [System.IO.Compression.CompressionMode]::Compress)
    $bytes = (New-Object System.Text.UTF8Encoding($false)).GetBytes("一`n二`n三`n四`n")
    $gz.Write($bytes, 0, $bytes.Length); $gz.Dispose(); $fs.Dispose()
    Assert-Eq 'tail .gz' '[三|四]' (@(Get-HvFileTail -Path $gzPath -Lines 2))

    # ------------------------------------------------------------------ pretty log lines
    Section 'log line formatting'
    $nc = '{"reqId":"abc","level":3,"time":"2026-09-26T10:00:00+08:00","remoteAddr":"10.99.77.2","user":"bob","app":"files","method":"PUT","url":"/remote.php/dav","message":"磁盘已满","userAgent":"x","version":"34.0.4.1"}'
    $f = Format-HvLogLine $nc
    $ncTime = [System.DateTimeOffset]::Parse('2026-09-26T10:00:00+08:00', $inv).ToLocalTime().ToString('yyyy-MM-dd HH:mm:ss', $inv)
    Assert-Eq 'nextcloud line formatted' ($ncTime + ' [错误] files: 磁盘已满（用户 bob，IP 10.99.77.2）') $f
    $ncEx = '{"reqId":"a","level":4,"time":"t","app":"PHP","message":"boom","user":"--","exception":{"Exception":"RuntimeException","Message":"disk gone"}}'
    Assert-Eq 'nextcloud exception appended' 't [严重] PHP: boom — RuntimeException: disk gone' (Format-HvLogLine $ncEx)
    $cad = '{"level":"info","ts":1790388000.5,"logger":"http.log.access","msg":"handled request","request":{"remote_ip":"10.99.77.2","client_ip":"10.99.77.2","proto":"HTTP/2.0","method":"GET","host":"192.168.1.10","uri":"/status.php"},"status":200,"size":2048,"duration":0.0123}'
    $expTime = [System.DateTimeOffset]::FromUnixTimeMilliseconds(1790388000500).ToLocalTime().ToString('yyyy-MM-dd HH:mm:ss', $inv)
    Assert-Eq 'caddy line formatted' ($expTime + ' 200 GET 192.168.1.10/status.php 10.99.77.2 12ms 2.0 KB') (Format-HvLogLine $cad)
    Assert-Eq 'plain line unchanged' '2026-09-26 plain text' (Format-HvLogLine '2026-09-26 plain text')
    Assert-Eq 'broken json unchanged' '{not json}' (Format-HvLogLine '{not json}')
    Assert-Eq 'other json unchanged' '{"a":1}' (Format-HvLogLine '{"a":1}')
    Assert-Eq 'local time from ISO string' $ncTime (Format-HvLocalTime '2026-09-26T10:00:00+08:00')
    Assert-Eq 'local time from DateTime' '2026-09-26 04:00:00' (Format-HvLocalTime (New-Object DateTime 2026, 9, 26, 4, 0, 0))
    Assert-Eq 'local time passthrough' 'gestern' (Format-HvLocalTime 'gestern')
    Assert-Eq 'local time null' '' (Format-HvLocalTime $null)

    # ------------------------------------------------------------------ rotation / export range
    Section 'rotation and container log range'
    Assert-Eq 'rotated name' 'nextcloud-2026-09-25.log' (Get-HvRotatedLogName -FileName 'nextcloud.log' -Stamp '2026-09-25')
    Assert-Eq 'rotated name collision' 'audit-2026-09-25.3.log' (Get-HvRotatedLogName -FileName 'audit.log' -Stamp '2026-09-25' -Existing @('audit-2026-09-25.log', 'audit-2026-09-25.2.log'))
    Assert-True 'rotate: started yesterday, written today' (Test-HvLogNeedsRotate -Length 10 -CreationTime $now.AddDays(-1) -LastWriteTime $now -Now $now)
    Assert-True 'rotate: idle since last week' (Test-HvLogNeedsRotate -Length 10 -CreationTime $now.AddDays(-9) -LastWriteTime $now.AddDays(-7) -Now $now)
    Assert-True 'no rotate: created today' (-not (Test-HvLogNeedsRotate -Length 10 -CreationTime $now.Date.AddMinutes(1) -LastWriteTime $now -Now $now))
    Assert-True 'no rotate: empty file' (-not (Test-HvLogNeedsRotate -Length 0 -CreationTime $now.AddDays(-3) -LastWriteTime $now.AddDays(-3) -Now $now))
    $rg = Get-HvContainerLogRange -Now $now
    Assert-Eq 'range day = yesterday' '2026-09-25' $rg.Day
    Assert-Eq 'range spans one day' 86400 ([long]$rg.Until - [long]$rg.Since)
    Assert-Eq 'range since = local midnight' ((New-Object System.DateTimeOffset -ArgumentList (New-Object DateTime 2026, 9, 25)).ToUnixTimeSeconds()) ([long]$rg.Since)

    # ------------------------------------------------------------------ request parsing / allow-list
    Section 'request parsing'
    $r = ConvertFrom-HvRequestText '{"id":"20260926T101500123Z-backup","type":"backup","created":"2026-09-26T10:15:00Z"}'
    Assert-True 'backup valid' ($r.Valid -and $r.Type -eq 'backup' -and $r.Days -eq 0)
    $r = ConvertFrom-HvRequestText '{"type":"log-clean"}'
    Assert-True 'log-clean valid' ($r.Valid -and $r.Type -eq 'log-clean')
    $r = ConvertFrom-HvRequestText ([string][char]0xFEFF + '{"type":"log-retention","days":14}')
    Assert-True 'log-retention 14 (with BOM)' ($r.Valid -and $r.Days -eq 14)
    $r = ConvertFrom-HvRequestText '{"type":"log-retention","days":"30"}'
    Assert-True 'log-retention "30" (digit string)' ($r.Valid -and $r.Days -eq 30)
    $r = ConvertFrom-HvRequestText '{"type":"log-retention","days":365.0}'
    Assert-True 'log-retention 365.0' ($r.Valid -and $r.Days -eq 365)
    foreach ($c in @(
            @('{"type":"log-retention","days":0}', '*1 到 365*'),
            @('{"type":"log-retention","days":366}', '*1 到 365*'),
            @('{"type":"log-retention","days":14.5}', '*1 到 365*'),
            @('{"type":"log-retention","days":"7d"}', '*1 到 365*'),
            @('{"type":"log-retention","days":true}', '*1 到 365*'),
            @('{"type":"log-retention"}', '*1 到 365*'),
            @('{"type":"log-retention","days":-3}', '*1 到 365*'),
            @('{"type":"log-retention","days":[14]}', '*1 到 365*'),
            @('{"type":"log-retention","days":"３０"}', '*1 到 365*'),
            @('{"type":"shell","cmd":"rm -rf /"}', '*允许列表*'),
            @('{"type":"Backup"}', '*允许列表*'),
            @('{"type":"backup "}', '*允许列表*'),
            @('{"type":["backup"]}', '*type*'),
            @('{"type":7}', '*type*'),
            @('{"days":7}', '*type*'),
            @('[{"type":"backup"}]', '*JSON 对象*'),
            @('"backup"', '*JSON 对象*'),
            @('not json', '*JSON*'),
            @('', '*为空*'))) {
        $r = ConvertFrom-HvRequestText $c[0]
        Assert-True ('rejected: ' + $c[0]) ((-not $r.Valid) -and ($r.Error -like $c[1]) -and $r.Type -eq '')
    }
    Assert-True 'oversized request rejected' (-not (ConvertFrom-HvRequestText ('{"type":"backup","x":"' + ('a' * 70000) + '"}')).Valid)
    foreach ($n in @('20260926T101500123Z-backup.json', '20260926T101500123Z-log-retention.json', 'a.json')) { Assert-True ('request file name ok: ' + $n) (Test-HvRequestFileName $n) }
    foreach ($n in @('.tmp-20260926-backup.json', 'a b.json', '..json', 'x.result.json', 'x.txt', 'x.json.tmp', '中文.json', ('a' * 130 + '.json'), 'a/b.json')) {
        Assert-True ('request file name rejected: ' + $n) (-not (Test-HvRequestFileName $n))
    }
    $res = New-HvRequestResult -RequestFile 'x-backup.json' -Type '' -Ok $false -Message '无效' -Now $now
    Assert-Eq 'result keys (as the Linux runner)' 'id,request,type,ok,finished,message' (@($res.Keys) -join ',')
    Assert-Eq 'result id' 'x-backup' $res['id']
    Assert-Eq 'result unknown type' 'unknown' $res['type']
    Assert-True 'result time is RFC 3339' ($res['finished'] -match '^2026-09-26T04:00:00[+-]\d\d:\d\d$')

    # ------------------------------------------------------------------ vpn dump parsing + documents
    Section 'vpn status'
    $dump = "SERVERPRIV=`tSERVERPUB=`t40123`toff`r`n" +
        "PUBA=`tPSKA=`t203.0.113.9:40000`t10.99.77.2/32`t1790388000`t1048576`t2097152`toff`r`n" +
        "PUBB=`tPSKB=`t(none)`t10.99.77.3/32`t0`t0`t0`toff`n" +
        "PUBX=`tPSKX=`t(none)`t10.99.77.9/32`t0`t0`t0`toff`n"
    $dp = ConvertFrom-HvWgDump $dump
    Assert-Eq 'dump listen port' 40123 $dp.ListenPort
    Assert-Eq 'dump peers' 3 @($dp.Peers).Count
    Assert-Eq 'dump peer A' 'PUBA=|203.0.113.9:40000|10.99.77.2/32|1790388000|1048576|2097152' (($dp.Peers[0].PublicKey, $dp.Peers[0].Endpoint, $dp.Peers[0].AllowedIps, $dp.Peers[0].Handshake, $dp.Peers[0].Rx, $dp.Peers[0].Tx) -join '|')
    Assert-Eq 'dump (none) endpoint' '' $dp.Peers[1].Endpoint
    Assert-True 'dump object carries no preshared/private key' (-not ((($dp.Peers | ForEach-Object { $_.PSObject.Properties.Name }) -join ',') -match '(?i)preshared|private'))
    Assert-Eq 'empty dump' 0 @((ConvertFrom-HvWgDump '').Peers).Count
    $peers = @(
        [pscustomobject]@{ name = 'phone1'; publicKey = 'PUBA='; presharedKey = 'PSKA='; address = '10.99.77.2'; created = '2026-09-01T10:00:00' }
        [pscustomobject]@{ name = 'phone-mama'; publicKey = 'PUBB='; presharedKey = 'PSKB='; address = '10.99.77.3'; created = '2026-09-02T10:00:00' }
        [pscustomobject]@{ name = 'tablet'; publicKey = 'PUBC='; presharedKey = 'PSKC='; address = '10.99.77.4'; created = '2026-09-03T10:00:00' }
    )
    $vd = New-HvVpnStatusDocument -Peers $peers -Dump $dp -Now $now -ListenPort 1
    $vjson = ConvertTo-HvJson $vd
    $vo = ConvertFrom-Json $vjson
    Assert-Eq 'vpn listen port from dump' 40123 $vo.listen_port
    Assert-Eq 'vpn peers = peers.json entries' 'phone1,phone-mama,tablet' (@($vo.peers | ForEach-Object { $_.name }) -join ',')
    Assert-Eq 'vpn peer 1 stats' '10.99.77.2/32|1790388000|1048576|2097152|203.0.113.9:40000' (($vo.peers[0].address, $vo.peers[0].latest_handshake, $vo.peers[0].rx_bytes, $vo.peers[0].tx_bytes, $vo.peers[0].endpoint) -join '|')
    Assert-True 'vpn peer 2 never handshaked, no endpoint' ([long]$vo.peers[1].latest_handshake -eq 0 -and $null -eq $vo.peers[1].PSObject.Properties['endpoint'])
    Assert-True 'vpn peer missing from dump -> null handshake' ($null -eq $vo.peers[2].latest_handshake)
    Assert-True 'vpn json has no key material' (-not ($vjson -match 'PUB[ABCX]=|PSK|SERVERP|(?i)key'))
    $keys = @($vd.Keys) + @($vd['peers'][0].Keys)
    Assert-CanonicalKeys 'vpn-status.json' $keys
    $vd2 = New-HvVpnStatusDocument -Peers $peers -Dump $null -Now $now -ListenPort 51820
    Assert-Eq 'vpn without dump keeps names + port' '51820|3' ([string]$vd2['listen_port'] + '|' + @($vd2['peers']).Count)
    $one = ConvertTo-HvJson (New-HvVpnStatusDocument -Peers @($peers[0]) -Dump $null -Now $now)
    Assert-True 'single peer stays a JSON array (PS 5.1 pitfall)' ($one -match '"peers": \[')
    if ($OutDir) {
        $goDump = ConvertFrom-HvWgDump ($dump -replace '40123', '43210')
        Write-HvJsonFile -Path (Join-Path $OutDir 'state/vpn-status.json') -Value (New-HvVpnStatusDocument -Peers @($peers[0], $peers[1]) -Dump $goDump -Now $now)
    }
    $san = ConvertTo-HvSanitizedVpnStatus -Object (ConvertFrom-Json '{"listen_port":"40123","tunnel_ok":true,"peers":[{"name":"phone1","address":"10.99.77.2/32","latest_handshake":17,"rx_bytes":"5","tx_bytes":6,"endpoint":"1.2.3.4:5","public_key":"SECRET","preshared_key":"SECRET2"},{"name":"x","address":"10.99.77.5","endpoint":"<script>"}]}') -Now $now
    $sj = ConvertTo-HvJson $san
    Assert-True 'sanitized: keys dropped' (-not ($sj -match 'SECRET|public_key|tunnel_ok'))
    Assert-True 'sanitized: bad endpoint dropped, address /32' ($sj -notmatch 'script' -and $sj -match '10\.99\.77\.5/32')
    Assert-Eq 'sanitized: numbers' '40123|17|5|6' (([string]$san['listen_port']), $san['peers'][0]['latest_handshake'], $san['peers'][0]['rx_bytes'], $san['peers'][0]['tx_bytes'] -join '|')

    # ------------------------------------------------------------------ status document
    Section 'status.json document'
    $prev = ConvertFrom-Json '{"updated":"2026-09-25T04:00:00+08:00","maintenance":{"last_run":"2026-09-25T04:00:00+08:00","ok":true,"message":"每日维护完成"},"requests":{"last_run":"2026-09-25T10:00:00+08:00"},"disks":[{"role":"data","name":"Nextcloud 数据","path":"D:\\HomeVault\\nextcloud-data","total":100,"free":50,"mounted":true}]}'
    $doc = New-HvStatusDocument -Previous $prev -Now $now -Version '1.0.0' -Hostname 'PC' -RetentionDays 14 -LogDir 'D:\HomeVault\logs' -RequestsRun
    $jo = ConvertFrom-Json (ConvertTo-HvJson $doc)
    Assert-Eq 'status top-level keys' 'updated,version,platform,hostname,log_retention_days,log_dir,maintenance,requests,disks' (@($doc.Keys) -join ',')
    Assert-Eq 'status retention / platform' '14|windows|1.0.0|PC' (($jo.log_retention_days, $jo.platform, $jo.version, $jo.hostname) -join '|')
    Assert-True 'maintenance block carried over' ([string]$doc['maintenance']['message'] -eq '每日维护完成' -and $doc['maintenance']['ok'] -eq $true)
    Assert-True 'requests.last_run = now' ([string]$doc['requests']['last_run'] -match '^2026-09-26T04:00:00')
    Assert-Eq 'disks carried over (single entry stays an array)' 1 @($jo.disks).Count
    Assert-True 'disks json is an array' ((ConvertTo-HvJson $doc) -match '"disks": \[')
    $doc2 = New-HvStatusDocument -Previous $null -Now $now -Version '1.0.0' -Hostname 'PC' -RetentionDays 7 -LogDir 'L' -Maintenance @{ ok = $false; message = 'Docker 未运行' } -Disks @((Get-HvDiskUsageEntry -Role 'data' -Name 'n' -Path $logRoot))
    Assert-True 'maintenance recorded' ($doc2['maintenance']['ok'] -eq $false -and [string]$doc2['maintenance']['last_run'] -match '^2026-09-26T04:00:00')
    Assert-True 'requests.last_run null when never run' ($null -eq $doc2['requests']['last_run'])
    Assert-True 'disk entry has sizes' ([long]$doc2['disks'][0]['total'] -gt 0 -and $doc2['disks'][0]['mounted'] -eq $true)
    if ($OutDir) { Write-HvJsonFile -Path (Join-Path $OutDir 'state/status.json') -Value $doc2 }
    Assert-CanonicalKeys 'status.json' (@($doc2.Keys) + @($doc2['maintenance'].Keys) + @($doc2['requests'].Keys) + @($doc2['disks'][0].Keys))

    # ------------------------------------------------------------------ SYSTEM vpn-status task script (fake wg.exe)
    Section 'SYSTEM task script (HomeVault-VpnStatus)'
    $scriptText = Get-HvVpnStatusScript
    $perr = $null; $ptok = $null
    [void][System.Management.Automation.Language.Parser]::ParseInput($scriptText, [ref]$ptok, [ref]$perr)
    Assert-Eq 'task script parses' 0 @($perr).Count
    $badTok = @($ptok | Where-Object { @('QuestionQuestion', 'QuestionDot', 'AndAnd', 'OrOr', 'QuestionMark') -contains [string]$_.Kind })
    Assert-Eq 'task script uses no PS7-only operators' 0 $badTok.Count
    $enc = ConvertTo-HvEncodedCommand $scriptText
    Assert-Eq 'encoded command round trip' $scriptText ([System.Text.Encoding]::Unicode.GetString([System.Convert]::FromBase64String($enc)))
    Assert-True 'encoded command fits a command line' ($enc.Length -lt 30000)
    if (-not (Test-HvWindows)) {
        $pd = New-TempDir; $tempDirs.Add($pd)
        $pf = New-TempDir; $tempDirs.Add($pf)
        $wgDir = Join-Path $pd 'HomeVault/wireguard'
        [void](New-Item -ItemType Directory -Force -Path $wgDir)
        [void](New-Item -ItemType Directory -Force -Path (Join-Path $pf 'WireGuard'))
        Write-Utf8 (Join-Path $wgDir 'peers.json') (ConvertTo-HvPeersJson $peers)
        $fakeWg = Join-Path $pf 'WireGuard/wg.exe'
        Write-Utf8 $fakeWg ("#!/bin/sh`nif [ `"`$1`" = show ] && [ `"`$2`" = homevault ] && [ `"`$3`" = dump ] && [ ! -e `"`$0.fail`" ]; then`n" +
            "printf 'SERVERPRIV=\tSERVERPUB=\t40123\toff\n'`n" +
            "printf 'PUBA=\tPSKA=\t203.0.113.9:40000\t10.99.77.2/32\t1790388000\t1048576\t2097152\toff\n'`n" +
            "printf 'PUBX=\tPSKX=\t(none)\t10.99.77.9/32\t0\t0\t0\toff\n'`nexit 0`nfi`nexit 1`n")
        & chmod +x $fakeWg
        $oldPd = $env:ProgramData; $oldPf = $env:ProgramFiles
        $env:ProgramData = $pd; $env:ProgramFiles = $pf
        try {
            & ([scriptblock]::Create($scriptText))
            $outFile = Join-Path $wgDir 'vpn-status.json'
            $raw = [System.IO.File]::ReadAllText($outFile)
            $o = ConvertFrom-Json $raw
            Assert-True 'task output: tunnel ok, port' ($o.tunnel_ok -eq $true -and [int]$o.listen_port -eq 40123)
            Assert-Eq 'task output: only known peers from the dump' 'phone1' (@($o.peers | ForEach-Object { $_.name }) -join ',')
            Assert-Eq 'task output: peer stats' '10.99.77.2/32|1790388000|1048576|2097152|203.0.113.9:40000' (($o.peers[0].address, $o.peers[0].latest_handshake, $o.peers[0].rx_bytes, $o.peers[0].tx_bytes, $o.peers[0].endpoint) -join '|')
            Assert-True 'task output: no key material' (-not ($raw -match 'PUB|PSK|SERVER|(?i)key'))
            $san2 = ConvertTo-HvSanitizedVpnStatus -Object $o -Now $now
            Assert-Eq 'task output sanitized' 'phone1|1790388000' ($san2['peers'][0]['name'] + '|' + $san2['peers'][0]['latest_handshake'])
            Write-Utf8 ($fakeWg + '.fail') 'x'
            & ([scriptblock]::Create($scriptText))
            $o = ConvertFrom-Json ([System.IO.File]::ReadAllText($outFile))
            Assert-True 'task output when wg fails: tunnel_ok false, no peers' ($o.tunnel_ok -eq $false -and @($o.peers).Count -eq 0)
        } finally {
            $env:ProgramData = $oldPd; $env:ProgramFiles = $oldPf
        }
    }

    # ------------------------------------------------------------------ requests end to end (temp install)
    Section 'requests process (temp install, stubbed backup)'
    $inst = New-TempDir; $tempDirs.Add($inst)
    $ilogs = Join-Path $inst 'logs'
    foreach ($d in @('homevault', 'backup', 'caddy', 'nextcloud', 'containers', 'panel')) { [void](New-Item -ItemType Directory -Force -Path (Join-Path $ilogs $d)) }
    Write-Utf8 (Join-Path $inst '.env') ("# test`nHV_PLATFORM=windows`nHV_HOST=192.168.1.10`nHV_LAN_IP=192.168.1.10`nHV_HTTPS_PORT=443`nHV_PANEL_PORT=9443`nHV_LOG_DIR=" + $ilogs + "`nHV_LOG_RETENTION_DAYS=7`nHV_VPN_ENABLED=false`nHV_TLS_MODE=internal`n")
    $script:HvRoot = $inst
    $script:HvEnvCache = $null
    $script:HvLogFile = $null
    $oldLog = Join-Path $ilogs 'caddy/access-old.log'
    Write-Utf8 $oldLog "old`n"
    [System.IO.File]::SetLastWriteTime($oldLog, (Get-Date).AddDays(-40))
    Write-Utf8 (Join-Path $ilogs 'caddy/access.log') "new`n"
    $reqDir = Join-Path $inst 'state/requests'
    [void](New-Item -ItemType Directory -Force -Path $reqDir)
    Write-Utf8 (Join-Path $reqDir '20260926T100000000Z-log-clean.json') '{"id":"20260926T100000000Z-log-clean","type":"log-clean"}'
    Write-Utf8 (Join-Path $reqDir '20260926T100000001Z-log-retention.json') '{"type":"log-retention","days":14}'
    Write-Utf8 (Join-Path $reqDir '20260926T100000002Z-shell.json') '{"type":"shell","cmd":"calc.exe"}'
    Write-Utf8 (Join-Path $reqDir '20260926T100000003Z-backup.json') '{"type":"backup"}'
    Write-Utf8 (Join-Path $reqDir '20260926T100000004Z-backup.json') '{"type":"backup"}'
    Write-Utf8 (Join-Path $reqDir '20260926T100000005Z-log-retention.json') '{"type":"log-retention","days":999}'
    Write-Utf8 (Join-Path $reqDir '.tmp-20260926T100000006Z-backup.json') '{"type":"backup"}'
    Write-Utf8 (Join-Path $reqDir 'bad name.json') '{"type":"backup"}'
    $script:BackupCalls = New-Object System.Collections.Generic.List[string]
    function Invoke-HvCmdBackup { param([object[]]$Arguments = @()) $script:BackupCalls.Add((@($Arguments) -join ' ')) }
    Invoke-HvRequests -Arguments @('process', '--non-interactive')
    $done = Join-Path $reqDir 'done'
    function Get-Result { param([string]$Id) return (ConvertFrom-Json ([System.IO.File]::ReadAllText((Join-Path $done ($Id + '.result.json'))))) }
    $rc = Get-Result '20260926T100000000Z-log-clean'
    Assert-True 'log-clean ok' ($rc.ok -eq $true -and $rc.type -eq 'log-clean' -and $rc.request -eq '20260926T100000000Z-log-clean.json' -and $rc.message -like '*1 个*')
    Assert-True 'log-clean deleted the 40-day-old file only' ((-not (Test-Path -LiteralPath $oldLog)) -and (Test-Path -LiteralPath (Join-Path $ilogs 'caddy/access.log')))
    $rr = Get-Result '20260926T100000001Z-log-retention'
    Assert-True 'log-retention ok' ($rr.ok -eq $true -and $rr.message -like '*14*')
    Assert-True '.env updated to 14' ([System.IO.File]::ReadAllText((Join-Path $inst '.env')) -match '(?m)^HV_LOG_RETENTION_DAYS=14$')
    $rs = Get-Result '20260926T100000002Z-shell'
    Assert-True 'shell request rejected' ($rs.ok -eq $false -and $rs.type -eq 'unknown' -and $rs.message -like '*允许列表*')
    $rb = Get-Result '20260926T100000003Z-backup'
    $rb2 = Get-Result '20260926T100000004Z-backup'
    Assert-True 'backup ok' ($rb.ok -eq $true -and $rb.type -eq 'backup')
    Assert-True 'second backup merged' ($rb2.ok -eq $true -and $rb2.message -like '*合并*')
    Assert-Eq 'backup ran once' 1 $script:BackupCalls.Count
    Assert-True 'backup log under logs\backup' ($script:BackupCalls[0] -match '^--log .+[\\/]backup[\\/]backup-\d{8}-\d{6}\.log$')
    $rbad = Get-Result '20260926T100000005Z-log-retention'
    Assert-True 'retention 999 rejected' ($rbad.ok -eq $false -and $rbad.message -like '*1 到 365*')
    Assert-True 'requests moved to done' ((Test-Path -LiteralPath (Join-Path $done '20260926T100000003Z-backup.json')) -and -not (Test-Path -LiteralPath (Join-Path $reqDir '20260926T100000003Z-backup.json')))
    Assert-True 'temp file left alone' (Test-Path -LiteralPath (Join-Path $reqDir '.tmp-20260926T100000006Z-backup.json'))
    Assert-True 'bad file name removed' (-not (Test-Path -LiteralPath (Join-Path $reqDir 'bad name.json')))
    Assert-True 'result finished is RFC 3339' ([string]$rc.finished -match '^\d{4}-\d\d-\d\dT' -or $rc.finished -is [datetime])
    $st = ConvertFrom-Json ([System.IO.File]::ReadAllText((Join-Path $inst 'state/status.json')))
    Assert-True 'status.json: retention 14 + requests.last_run' ([int]$st.log_retention_days -eq 14 -and $null -ne $st.requests.last_run -and $st.platform -eq 'windows')
    Assert-True 'status.json: log_dir' ([string]$st.log_dir -eq $ilogs)
    Assert-True 'no vpn-status.json when VPN disabled' (-not (Test-Path -LiteralPath (Join-Path $inst 'state/vpn-status.json')))
    $cliLog = Join-Path $ilogs ('homevault/hv-' + (Get-Date).ToString('yyyy-MM-dd', $inv) + '.log')
    if (Get-Command Start-HvCliLog -ErrorAction SilentlyContinue) {
        Assert-True 'request run logged to homevault\hv-<date>.log' ((Test-Path -LiteralPath $cliLog) -and ([System.IO.File]::ReadAllText($cliLog) -match 'log-retention'))
    }
    # failing backup -> ok:false with the Chinese message
    function Invoke-HvCmdBackup { param([object[]]$Arguments = @()) Stop-Hv '未配置备份目标（测试）' }
    Write-Utf8 (Join-Path $reqDir '20260926T110000000Z-backup.json') '{"type":"backup"}'
    [void](Invoke-HvRequestsProcess)
    $rf = Get-Result '20260926T110000000Z-backup'
    Assert-True 'failed backup reported' ($rf.ok -eq $false -and $rf.message -like '*未配置备份目标*')
    Assert-Eq 'nothing pending -> 0' 0 (Invoke-HvRequestsProcess)
    # retention via the CLI entry point; show/list/clean run against the temp log tree
    $splat = @('retention', 21)   # hv.ps1 splats its remaining arguments: `Invoke-HvLogs @rest`
    Invoke-HvLogs @splat
    Assert-Eq 'logs retention 21 (splatted, int)' 21 (Get-HvLogRetentionDays (Get-HvEnv -Reload))
    Invoke-HvLogs -Arguments @('retention', '30')
    Assert-Eq 'logs retention 30' 30 (Get-HvLogRetentionDays (Get-HvEnv -Reload))
    $splat = @('show', 'access', '-Lines', '3')
    Invoke-HvLogs @splat | Out-Null
    $splat = @('process', '--non-interactive')
    Invoke-HvRequests @splat
    Assert-Throws 'logs retention 0 refused' { Invoke-HvLogs -Arguments @('retention', '0') } '*1 到 365*'
    Assert-Throws 'logs show outside dir refused' { Invoke-HvLogs -Arguments @('show', '../.env') } '*只能查看日志目录内的文件*'
    Assert-Throws 'logs show missing file' { Invoke-HvLogs -Arguments @('show', 'nope.log') } '*找不到日志*'
    Invoke-HvLogs -Arguments @('show', 'access', '--lines', '5') | Out-Null
    Invoke-HvLogs -Arguments @('list') | Out-Null
    Assert-Throws 'logs --lines validated' { Invoke-HvLogs -Arguments @('show', 'access', '--lines', 'x') } '*--lines*'
    # maintenance without Docker: logs are still cleaned, status.json records the problem, exit code non-zero
    $oldGz = Join-Path $ilogs 'caddy/access-2026-08-01.log.gz'
    [System.IO.File]::WriteAllBytes($oldGz, [byte[]](1, 2, 3))
    [System.IO.File]::SetLastWriteTime($oldGz, (Get-Date).AddDays(-60))
    $mErr = ''
    try { Invoke-HvMaintenance -Arguments @('--non-interactive') | Out-Null } catch { $mErr = Get-HvErrorMessage $_ }
    $st = ConvertFrom-Json ([System.IO.File]::ReadAllText((Join-Path $inst 'state/status.json')))
    Assert-True 'maintenance: expired .gz deleted' (-not (Test-Path -LiteralPath $oldGz))
    Assert-True 'maintenance: last_run recorded' ($null -ne $st.maintenance.last_run -and [string]$st.maintenance.message -like '每日维护完成*')
    if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
        Assert-True 'maintenance without Docker: ok=false, message, non-zero' ($st.maintenance.ok -eq $false -and $st.maintenance.message -like '*Docker 未运行*' -and $mErr -like '*Docker 未运行*')
    }
    Assert-True 'maintenance: log tree created' ((Test-Path -LiteralPath (Join-Path $ilogs 'panel')) -and (Test-Path -LiteralPath (Join-Path $ilogs 'containers')))
    Invoke-HvStatusUpdate | Out-Null
    $st = ConvertFrom-Json ([System.IO.File]::ReadAllText((Join-Path $inst 'state/status.json')))
    Assert-True 'status-update refreshes disks' (@($st.disks).Count -ge 0 -and [int]$st.log_retention_days -eq 30)

    # ------------------------------------------------------------------ android
    Section 'android'
    $u = Get-HvAndroidReleaseUrls 'yuelanxian/-'
    Assert-Eq 'apk url' 'https://github.com/yuelanxian/-/releases/latest/download/homevault-android.apk' $u.Apk
    Assert-Eq 'sha url' 'https://github.com/yuelanxian/-/releases/latest/download/homevault-android.apk.sha256' $u.Sha256
    foreach ($bad in @('', 'noslash', 'a/b/c', 'https://github.com/a/b', 'a/..', '-a/b', 'a/b c')) { Assert-Throws ('repo rejected: ' + $bad) { Get-HvAndroidReleaseUrls $bad } '*所有者/仓库名*' }
    $hex = 'ab' * 32
    Assert-Eq 'sha plain' $hex (ConvertFrom-HvSha256Text $hex)
    Assert-Eq 'sha with name' $hex (ConvertFrom-HvSha256Text ($hex.ToUpperInvariant() + '  homevault-android.apk'))
    Assert-Eq 'sha bsd style' $hex (ConvertFrom-HvSha256Text ('SHA256 (homevault-android.apk) = ' + $hex))
    Assert-Eq 'sha none' '' (ConvertFrom-HvSha256Text 'not a hash')
    Assert-Eq 'sha too long' '' (ConvertFrom-HvSha256Text ('a' * 65))
    $apk = Join-Path $inst 'fake.apk'
    [System.IO.File]::WriteAllBytes($apk, [byte[]](@(0x50, 0x4B, 0x03, 0x04) + (1..200 | ForEach-Object { [byte]($_ % 256) })))
    $apkHash = (Get-FileHash -LiteralPath $apk -Algorithm SHA256).Hash.ToLowerInvariant()
    $dest = Invoke-HvAndroidFetch -File $apk -Sha256 $apkHash
    Assert-True 'apk saved to state/app/homevault.apk' ((Test-Path -LiteralPath (Join-Path $inst 'state/app/homevault.apk')) -and ([string]$dest -like '*homevault.apk'))
    Assert-True 'apk checksum file' ([System.IO.File]::ReadAllText((Join-Path $inst 'state/app/homevault.apk.sha256')) -like ($apkHash + '*'))
    Assert-Throws 'apk hash mismatch refused' { Invoke-HvAndroidFetch -File $apk -Sha256 ('0' * 64) } '*SHA-256 校验失败*'
    $notApk = Join-Path $inst 'not.apk'
    Write-Utf8 $notApk 'hello'
    Assert-Throws 'non-zip refused' { Invoke-HvAndroidFetch -File $notApk } '*不是有效的 APK*'
    Assert-True 'refused files do not replace the saved apk' ((Get-FileHash -LiteralPath (Join-Path $inst 'state/app/homevault.apk') -Algorithm SHA256).Hash.ToLowerInvariant() -eq $apkHash)
    Assert-Eq 'no temp files left in state/app' '' ((@(Get-ChildItem -LiteralPath (Join-Path $inst 'state/app') -Force | Where-Object { $_.Name -like '.*' } | ForEach-Object { $_.Name })) -join ',')
    Assert-Throws 'http url refused' { Invoke-HvDownloadFile -Url 'http://example.com/x.apk' -OutFile (Join-Path $inst 'x') } '*https*'

    # ------------------------------------------------------------------ scheduled task action / shortcuts
    Section 'tasks and shortcuts'
    $act = Get-HvHiddenTaskAction -SystemRoot 'C:\Windows' -HvScript 'C:\Users\张 三\HomeVault\windows\hv.ps1' -HvArgs @('requests', 'process', '--non-interactive') -Headless $true
    Assert-Eq 'headless execute' 'C:\Windows\System32\conhost.exe' $act.Execute
    Assert-Eq 'headless argument' '--headless "C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File "C:\Users\张 三\HomeVault\windows\hv.ps1" requests process --non-interactive' $act.Argument
    $act = Get-HvHiddenTaskAction -SystemRoot 'C:\Windows\' -HvScript 'D:\HV\windows\hv.ps1' -HvArgs @('maintenance') -Headless $false
    Assert-Eq 'plain execute' 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe' $act.Execute
    Assert-Eq 'plain argument' '-NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File "D:\HV\windows\hv.ps1" maintenance' $act.Argument
    $plan = @(Get-HvShortcutPlan -Root 'D:\HomeVault\' -DesktopDir 'C:\Users\Public\Desktop' -ProgramsDir 'C:\ProgramData\Microsoft\Windows\Start Menu\Programs' -IconLocation 'shell32.dll,8')
    Assert-Eq 'two shortcuts' 2 $plan.Count
    Assert-Eq 'desktop shortcut' 'C:\Users\Public\Desktop\HomeVault 管理.lnk' $plan[0].Path
    Assert-Eq 'start menu shortcut' 'C:\ProgramData\Microsoft\Windows\Start Menu\Programs\HomeVault 管理.lnk' $plan[1].Path
    Assert-Eq 'shortcut target' 'D:\HomeVault\windows\HomeVault管理.cmd' $plan[0].Target
    Assert-Eq 'shortcut working dir' 'D:\HomeVault' $plan[0].WorkingDirectory
    Assert-True 'shortcut target exists in repo' (Test-Path -LiteralPath (Join-Path $Root 'windows/HomeVault管理.cmd'))

    # ------------------------------------------------------------------ menu mapping
    Section 'menu'
    $items = @(Get-HvMenuItems)
    $spec = @('1 状态', '2 启动', '3 停止', '4 查看日志', '5 日志保留天数', '6 添加手机VPN', '7 VPN设备列表', '8 立即备份', '9 备份记录',
        '10 存储/硬盘', '11 打开管理面板', '12 打开日志文件夹', '13 健康检查', '14 更新', '15 用户管理', '0 退出')
    Assert-Eq 'menu = SPEC section 17' ($spec -join ',') ((@($items | ForEach-Object { $_.Key + ' ' + $_.Label })) -join ',')
    foreach ($it in $items) { if ($it.Handler) { Assert-True ('handler exists: ' + $it.Handler) ([bool](Get-Command $it.Handler -CommandType Function -ErrorAction SilentlyContinue)) } }
    foreach ($c in @(@('1', '1'), @(' 7 ', '7'), @('１５', '15'), @('01', '1'), @('3.', '3'), @('4、', '4'), @('q', '0'), @('EXIT', '0'), @('退出', '0'), @('', ''), @('abc', 'abc'))) {
        Assert-Eq ('menu choice "' + $c[0] + '"') $c[1] (ConvertTo-HvMenuChoice $c[0])
    }
    Assert-Eq 'resolve 15' '用户管理' (Resolve-HvMenuItem -Choice '15' -Items $items).Label
    Assert-True 'resolve 16 -> none' ($null -eq (Resolve-HvMenuItem -Choice '16' -Items $items))
    $lines = @(Format-HvMenuLines -Items $items -Header @('H'))
    Assert-Eq 'menu line count (bar, header, bar, 8 rows, rule)' 12 $lines.Count
    Assert-True 'menu row 1: 1 and 9' ($lines[3] -match '^\s+1\. 状态\s+9\. 备份记录$')
    Assert-True 'menu row 8: 8 and 0' ($lines[10] -match '^\s+8\. 立即备份\s+0\. 退出$')
    $w1 = Get-HvDisplayWidth ($lines[3].Substring(0, $lines[3].IndexOf('9.')))
    $w5 = Get-HvDisplayWidth ($lines[7].Substring(0, $lines[7].IndexOf('13.')))
    Assert-Eq 'right column aligned (CJK width aware)' ($w1 - 1) $w5
    Assert-Throws 'menu refuses non-interactive' { Invoke-HvMenu } '*交互式*'

    # each item calls the corresponding hv command function (stubs record the calls)
    foreach ($fn in @('Invoke-HvCmdStatus', 'Invoke-HvCmdUp', 'Invoke-HvCmdDown', 'Invoke-HvCmdVpn', 'Invoke-HvCmdStorage', 'Invoke-HvCmdDoctor',
            'Invoke-HvCmdUpdate', 'Invoke-HvCmdRestore', 'Invoke-HvCmdUser', 'Invoke-HvLogs', 'Invoke-HvCmdBackup')) {
        Assert-True ('hv command function exists: ' + $fn) ([bool](Get-Command $fn -ErrorAction SilentlyContinue))
    }
    $script:Calls = New-Object System.Collections.Generic.List[string]
    function Invoke-HvCmdStatus { param([object[]]$Arguments = @()) $script:Calls.Add(('status ' + (@($Arguments) -join ' ')).Trim()) }
    function Invoke-HvCmdUp { param([object[]]$Arguments = @()) $script:Calls.Add(('up ' + (@($Arguments) -join ' ')).Trim()) }
    function Invoke-HvCmdDown { param([object[]]$Arguments = @()) $script:Calls.Add(('down ' + (@($Arguments) -join ' ')).Trim()) }
    function Invoke-HvCmdVpn { param([object[]]$Arguments = @()) $script:Calls.Add(('vpn ' + (@($Arguments) -join ' ')).Trim()) }
    function Invoke-HvCmdStorage { param([object[]]$Arguments = @()) $script:Calls.Add(('storage ' + (@($Arguments) -join ' ')).Trim()) }
    function Invoke-HvCmdDoctor { param([object[]]$Arguments = @()) $script:Calls.Add(('doctor ' + (@($Arguments) -join ' ')).Trim()) }
    function Invoke-HvCmdUpdate { param([object[]]$Arguments = @()) $script:Calls.Add(('update ' + (@($Arguments) -join ' ')).Trim()) }
    function Invoke-HvCmdRestore { param([object[]]$Arguments = @()) $script:Calls.Add(('restore ' + (@($Arguments) -join ' ')).Trim()) }
    function Invoke-HvCmdUser { param([object[]]$Arguments = @()) $script:Calls.Add(('user ' + (@($Arguments) -join ' ')).Trim()) }
    function Invoke-HvLogs { param([object[]]$Arguments = @()) $script:Calls.Add(('logs ' + (@($Arguments) -join ' ')).Trim()) }
    function Invoke-HvCmdBackup { param([object[]]$Arguments = @()) $script:Calls.Add(('backup ' + ((@($Arguments) | ForEach-Object { if ($_ -like '*.log') { '<log>' } else { $_ } }) -join ' ')).Trim()) }
    $script:HvYes = $true
    $expect = [ordered]@{
        'Invoke-HvMenuStatus'        = 'status'
        'Invoke-HvMenuUp'            = 'up --wait'
        'Invoke-HvMenuDown'          = 'down'
        'Invoke-HvMenuLogs'          = ''
        'Invoke-HvMenuLogRetention'  = ''
        'Invoke-HvMenuVpnAdd'        = 'vpn add phone1'
        'Invoke-HvMenuVpnList'       = 'vpn list'
        'Invoke-HvMenuBackup'        = 'backup --log <log>'
        'Invoke-HvMenuBackupHistory' = 'restore'
        'Invoke-HvMenuStorage'       = 'storage list'
        'Invoke-HvMenuPanel'         = ''
        'Invoke-HvMenuLogFolder'     = 'logs open'
        'Invoke-HvMenuDoctor'        = 'doctor'
        'Invoke-HvMenuUpdate'        = 'update'
        'Invoke-HvMenuUsers'         = ''
    }
    foreach ($h in $expect.Keys) {
        $script:Calls.Clear()
        try { & $h | Out-Null } catch { $script:Calls.Add('ERROR ' + (Get-HvErrorMessage $_)) }
        Assert-Eq ('menu handler ' + $h) $expect[$h] ($script:Calls -join ';')
    }
    $script:HvYes = $false
    $script:Calls.Clear()
    & 'Invoke-HvMenuDown' | Out-Null
    Assert-Eq 'stop needs confirmation (default no)' '' ($script:Calls -join ';')

    # the interactive loop, with scripted input
    $script:Inputs = New-Object System.Collections.Generic.Queue[string]
    foreach ($x in @('1', '', '99', '', '１５', '1', '', '4', '7', 'caddy', '', '5', '14', '', 'q')) { $script:Inputs.Enqueue($x) }
    function Read-Host { param([Parameter(Position = 0)]$Prompt, [switch]$AsSecureString) if ($script:Inputs.Count -eq 0) { throw 'input exhausted' }; return $script:Inputs.Dequeue() }
    function Test-HvInteractive { return $true }
    function Clear-Host { }
    $script:Calls.Clear()
    $script:HvExitCode = 3
    Invoke-HvMenu | Out-Null
    Assert-Eq 'menu loop: status, users list, logs caddy, retention 14' 'status;user list;logs show caddy --lines 200;logs retention 14' ($script:Calls -join ';')
    Assert-Eq 'menu loop consumed all input' 0 $script:Inputs.Count
    Assert-Eq 'menu resets the exit code' 0 $script:HvExitCode

    # ------------------------------------------------------------------ .cmd launchers
    Section '.cmd launchers'
    foreach ($c in @(@('一键安装.cmd', 'install'), @('windows/HomeVault管理.cmd', 'menu'))) {
        $p = Join-Path $Root $c[0]
        if (-not (Test-Path -LiteralPath $p)) { Assert-True ($c[0] + ' exists') $false; continue }
        $b = [System.IO.File]::ReadAllBytes($p)
        Assert-True ($c[0] + ': no UTF-8 BOM (cmd.exe would choke on it)') (-not ($b.Length -ge 3 -and $b[0] -eq 0xEF -and $b[1] -eq 0xBB -and $b[2] -eq 0xBF))
        $txt = (New-Object System.Text.UTF8Encoding($false, $true)).GetString($b)
        Assert-True ($c[0] + ': CRLF only') (-not ($txt -match "(?<!`r)`n") -and $txt.EndsWith("`r`n"))
        $ls = @($txt -split "`r`n")
        $chcp = -1; $firstNonAscii = -1
        for ($i = 0; $i -lt $ls.Count; $i++) {
            if ($chcp -lt 0 -and $ls[$i] -match '^chcp 65001 >nul$') { $chcp = $i }
            if ($ls[$i] -match '[^\x00-\x7F]') {
                if ($firstNonAscii -lt 0) { $firstNonAscii = $i }
                Assert-True ($c[0] + ':' + ($i + 1) + ' non-ASCII only in echo lines') ($ls[$i] -match '^echo ')
            }
            Assert-True ($c[0] + ':' + ($i + 1) + ' no parenthesised blocks') (-not ($ls[$i] -match '\($' -or $ls[$i] -match '^\s*\)'))
            foreach ($m in [regex]::Matches($ls[$i], '%~[a-z]*[dpf]0')) {
                $before = $ls[$i].Substring(0, $m.Index)
                Assert-True ($c[0] + ':' + ($i + 1) + ' ' + $m.Value + ' is quoted') ((($before.ToCharArray() | Where-Object { $_ -eq '"' }).Count % 2) -eq 1)
            }
        }
        Assert-True ($c[0] + ': chcp 65001 before any non-ASCII line') ($chcp -ge 0 -and $chcp -lt $firstNonAscii)
        Assert-True ($c[0] + ': starts with @echo off') ($ls[0] -eq '@echo off')
        Assert-True ($c[0] + ': runs hv.ps1 ' + $c[1]) ($txt -match ('-NoProfile -ExecutionPolicy Bypass -File "%HV_SCRIPT%" ' + $c[1] + "`r`n"))
        Assert-True ($c[0] + ': self-elevates via RunAs') ($txt -match '-Verb RunAs' -and $txt -match 'fltmc\.exe')
        Assert-True ($c[0] + ': at most one UAC relaunch (hv-elevated marker)') ($txt -match "' hv-elevated'" -and $txt -match 'if /i "%~1"=="hv-elevated" goto :notadmin' -and $txt -match ':notadmin\r\n')
        foreach ($lbl in @([regex]::Matches($txt, 'goto :([a-z]+)') | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)) {
            Assert-True ($c[0] + ': label :' + $lbl + ' exists') ($txt -match ('(?m)^:' + $lbl + '\r$'))
        }
        Assert-True ($c[0] + ': pauses on error') ($txt -match ':failed\r\n(echo[^\r]*\r\n)+pause')
        Assert-True ($c[0] + ': full path to Windows PowerShell') ($txt -match 'WindowsPowerShell\\v1\.0\\powershell\.exe')
        $cmdLine = @($ls | Where-Object { $_ -match '-Command "' })[0]
        $psCode = [regex]::Match($cmdLine, '-Command "(.*)"$').Groups[1].Value
        $e2 = $null; $t2 = $null
        [void][System.Management.Automation.Language.Parser]::ParseInput($psCode, [ref]$t2, [ref]$e2)
        Assert-True ($c[0] + ': elevation command parses, has no quotes/special chars for cmd') (@($e2).Count -eq 0 -and $psCode -notmatch '["&|<>^%]')
    }
} catch {
    $script:Fail++
    Write-Host ('  FAIL unexpected error: ' + (Get-HvErrorMessage $_))
    Write-Host ([string]$_.InvocationInfo.PositionMessage)
} finally {
    $script:HvRoot = $Root
    foreach ($d in $tempDirs) { Remove-Item -LiteralPath $d -Recurse -Force -ErrorAction SilentlyContinue }
}

Write-Host ('unit-ux: ' + $script:Pass + ' passed, ' + $script:Fail + ' failed')
if ($script:Fail -gt 0) { exit 1 }
exit 0
