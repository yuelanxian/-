# HomeVault Windows CLI - host status files for the management panel (SPEC section 15):
# state\status.json and state\vpn-status.json. Canonical field names = json tags of
# panel/internal/hoststate/types.go (Status, HostDisk, VPNStatus, VPNPeer). Never write key material.

$script:HvVpnStatusMaxAgeMin = 10

function Get-HvStateDir { return (Get-HvPath 'state') }

function Read-HvStateJson {
    # Parsed state\<Name> or $null (missing / unreadable / invalid JSON).
    param([string]$Name)
    $p = Join-HvPath (Get-HvStateDir) $Name
    if (-not [System.IO.File]::Exists($p)) { return $null }
    try {
        $t = (Read-HvTextFile $p).TrimStart([char]0xFEFF).Trim()
        if ($t -eq '') { return $null }
        return (ConvertFrom-Json -InputObject $t)
    } catch { return $null }
}

# ---------------------------------------------------------------- pure builders

function New-HvStatusDocument {
    # Pure: canonical state/status.json. Blocks this run does not update (maintenance, requests, disks) are
    # carried over from $Previous (the parsed old file, or $null).
    param(
        $Previous = $null,
        [datetime]$Now,
        [string]$Version = '',
        [string]$Hostname = '',
        [int]$RetentionDays = 7,
        [string]$LogDir = '',
        [AllowNull()][hashtable]$Maintenance = $null,
        [switch]$RequestsRun,
        [AllowNull()][object[]]$Disks = $null
    )
    $prevM = Get-HvPropValue $Previous 'maintenance'
    $prevR = Get-HvPropValue $Previous 'requests'
    $m = [ordered]@{ last_run = $null; ok = $null; message = '' }
    if ($null -ne $Maintenance) {
        $m['last_run'] = Format-HvIsoTime $Now
        $m['ok'] = [bool]$Maintenance['ok']
        $m['message'] = [string]$Maintenance['message']
    } elseif ($null -ne $prevM) {
        $m['last_run'] = Get-HvPropValue $prevM 'last_run'
        $okPrev = Get-HvPropValue $prevM 'ok'
        if ($null -ne $okPrev) { $m['ok'] = [bool]$okPrev }
        $m['message'] = [string](Get-HvPropValue $prevM 'message' '')
    }
    $r = [ordered]@{ last_run = $null }
    if ($RequestsRun) { $r['last_run'] = Format-HvIsoTime $Now } elseif ($null -ne $prevR) { $r['last_run'] = Get-HvPropValue $prevR 'last_run' }
    $doc = [ordered]@{
        updated            = (Format-HvIsoTime $Now)
        version            = $Version
        platform           = 'windows'
        hostname           = $Hostname
        log_retention_days = $RetentionDays
        log_dir            = $LogDir
        maintenance        = $m
        requests           = $r
    }
    $d = $null
    if ($null -ne $Disks) { $d = @($Disks) } else { $pd = Get-HvPropValue $Previous 'disks'; if ($null -ne $pd) { $d = @($pd) } }
    if ($null -ne $d -and $d.Count -gt 0) { $doc['disks'] = $d }
    return $doc
}

function ConvertFrom-HvWgDump {
    # Pure: parse `wg show <interface> dump` (tab separated). Line 1 = interface (private key, public key,
    # listen port, fwmark); then per peer: public key, preshared key, endpoint, allowed ips, latest handshake,
    # rx, tx, keepalive. Only the public key is kept (for matching); keys are never returned otherwise.
    param([AllowEmptyString()][AllowNull()][string]$Text)
    $lines = @(([string]$Text) -split "`r?`n" | Where-Object { $_ -ne '' })
    $port = 0
    $peers = New-Object System.Collections.Generic.List[object]
    if ($lines.Count -gt 0) {
        $f0 = @($lines[0] -split "`t")
        if ($f0.Count -ge 3) { [void][int]::TryParse($f0[2], [ref]$port) }
        for ($i = 1; $i -lt $lines.Count; $i++) {
            $f = @($lines[$i] -split "`t")
            if ($f.Count -lt 7) { continue }
            $hs = [int64]0; $rx = [int64]0; $tx = [int64]0
            [void][int64]::TryParse($f[4], [ref]$hs)
            [void][int64]::TryParse($f[5], [ref]$rx)
            [void][int64]::TryParse($f[6], [ref]$tx)
            $ep = [string]$f[2]
            if ($ep -eq '(none)') { $ep = '' }
            $peers.Add([pscustomobject]@{ PublicKey = [string]$f[0]; Endpoint = $ep; AllowedIps = [string]$f[3]; Handshake = $hs; Rx = $rx; Tx = $tx })
        }
    }
    return [pscustomobject]@{ ListenPort = $port; Peers = $peers.ToArray() }
}

function ConvertTo-HvVpnAddress {
    param([AllowEmptyString()][string]$Address)
    $a = ([string]$Address).Trim()
    if ($a -and $a -notmatch '/') { $a += '/32' }
    return $a
}

function New-HvVpnStatusDocument {
    # Pure: canonical state/vpn-status.json from peers.json entries (name, address, publicKey) and an optional
    # parsed dump (ConvertFrom-HvWgDump); only peers known to peers.json are listed. No key material.
    param([object[]]$Peers = @(), $Dump = $null, [datetime]$Now, [int]$ListenPort = 0, [string]$Interface = 'homevault')
    $byKey = @{}
    if ($null -ne $Dump) {
        foreach ($d in @($Dump.Peers)) { if ($null -ne $d) { $byKey[[string]$d.PublicKey] = $d } }
        if ([int]$Dump.ListenPort -gt 0) { $ListenPort = [int]$Dump.ListenPort }
    }
    $list = New-Object System.Collections.Generic.List[object]
    foreach ($p in @($Peers)) {
        if ($null -eq $p) { continue }
        $e = [ordered]@{
            name             = [string](Get-HvPropValue $p 'name' '')
            address          = (ConvertTo-HvVpnAddress ([string](Get-HvPropValue $p 'address' '')))
            enabled          = $true
            latest_handshake = $null
            rx_bytes         = [int64]0
            tx_bytes         = [int64]0
        }
        $k = [string](Get-HvPropValue $p 'publicKey' '')
        if ($k -and $byKey.ContainsKey($k)) {
            $d = $byKey[$k]
            $e['latest_handshake'] = [int64]$d.Handshake
            $e['rx_bytes'] = [int64]$d.Rx
            $e['tx_bytes'] = [int64]$d.Tx
            if ($d.Endpoint) { $e['endpoint'] = [string]$d.Endpoint }
        }
        $list.Add($e)
    }
    return [ordered]@{
        updated     = (Format-HvIsoTime $Now)
        platform    = 'windows'
        interface   = $Interface
        listen_port = $ListenPort
        peers       = $list.ToArray()
    }
}

function ConvertTo-HvSanitizedVpnStatus {
    # Pure: re-build a vpn-status document written by the SYSTEM task (HomeVault-VpnStatus) keeping only the
    # canonical, non-secret fields with the right types.
    param($Object, [datetime]$Now)
    $list = New-Object System.Collections.Generic.List[object]
    foreach ($p in @(Get-HvPropValue $Object 'peers' @())) {
        if ($null -eq $p) { continue }
        $e = [ordered]@{
            name             = [string](Get-HvPropValue $p 'name' '')
            address          = (ConvertTo-HvVpnAddress ([string](Get-HvPropValue $p 'address' '')))
            enabled          = $true
            latest_handshake = $null
            rx_bytes         = [int64]0
            tx_bytes         = [int64]0
        }
        $n = [int64]0
        if ([int64]::TryParse([string](Get-HvPropValue $p 'latest_handshake' ''), [ref]$n)) { $e['latest_handshake'] = $n }
        if ([int64]::TryParse([string](Get-HvPropValue $p 'rx_bytes' ''), [ref]$n)) { $e['rx_bytes'] = $n }
        if ([int64]::TryParse([string](Get-HvPropValue $p 'tx_bytes' ''), [ref]$n)) { $e['tx_bytes'] = $n }
        $ep = [string](Get-HvPropValue $p 'endpoint' '')
        if ($ep -match '^[0-9A-Fa-f.:\[\]]+$') { $e['endpoint'] = $ep }
        $list.Add($e)
    }
    $port = 0
    [void][int]::TryParse([string](Get-HvPropValue $Object 'listen_port' '0'), [ref]$port)
    return [ordered]@{
        updated     = (Format-HvIsoTime $Now)
        platform    = 'windows'
        interface   = 'homevault'
        listen_port = $port
        peers       = $list.ToArray()
    }
}

# ---------------------------------------------------------------- runtime

function Get-HvDiskUsageEntry {
    param([string]$Role, [string]$Name, [string]$Path)
    $total = [int64]0; $free = [int64]0; $mounted = $false
    try {
        $mounted = [System.IO.Directory]::Exists($Path)
        $root = [System.IO.Path]::GetPathRoot($Path)
        if ($root) {
            $di = New-Object System.IO.DriveInfo($root)
            if ($di.IsReady) { $total = [int64]$di.TotalSize; $free = [int64]$di.AvailableFreeSpace }
        }
    } catch { }
    return [ordered]@{ role = $Role; name = $Name; path = $Path; total = $total; free = $free; mounted = $mounted }
}

function Get-HvStatusDisks {
    # Optional "disks" of status.json (the panel prefers its /stat mounts): data, extra storages, local backup, system drive.
    $e = Get-HvEnv
    $out = @()
    $nc = Get-HvEnvDictValue $e 'HV_NC_DATA_PATH'
    if ($nc) { $out += (Get-HvDiskUsageEntry -Role 'data' -Name 'Nextcloud 数据' -Path $nc) }
    $rows = @()
    try { $rows = @(Get-HvStorageRows) } catch { }
    foreach ($r in $rows) { $out += (Get-HvDiskUsageEntry -Role 'storage' -Name ([string]$r.Name) -Path ([string]$r.Path)) }
    if ((Get-HvEnvDictValue $e 'HV_BACKUP_TARGET') -eq 'local') {
        $bp = Get-HvEnvDictValue $e 'HV_BACKUP_LOCAL_PATH'
        if ($bp) { $out += (Get-HvDiskUsageEntry -Role 'backup' -Name 'restic 备份仓库' -Path $bp) }
    }
    if (Test-HvWindows) {
        $sd = [System.Environment]::GetEnvironmentVariable('SystemDrive')
        if ($sd) { $out += (Get-HvDiskUsageEntry -Role 'system' -Name '系统盘（Docker Desktop 数据默认在此）' -Path ($sd + '\')) }
    }
    return $out
}

function Update-HvStatusFile {
    # Write state\status.json. -Maintenance @{ ok; message } records a maintenance run, -RequestsRun a request-runner
    # run, -IncludeDisks refreshes the disk list (otherwise the previous one is kept - no disk access every 2 minutes).
    param([AllowNull()][hashtable]$Maintenance = $null, [switch]$RequestsRun, [switch]$IncludeDisks)
    $e = Get-HvEnv
    $logDir = ''
    try { $logDir = Get-HvLogDir } catch { }
    $disks = $null
    if ($IncludeDisks) { $disks = @(Get-HvStatusDisks) }
    $doc = New-HvStatusDocument -Previous (Read-HvStateJson 'status.json') -Now (Get-Date) -Version ([string]$script:HvVersion) `
        -Hostname ([System.Environment]::MachineName) -RetentionDays (Get-HvLogRetentionDays $e) -LogDir $logDir `
        -Maintenance $Maintenance -RequestsRun:$RequestsRun -Disks $disks
    $state = New-HvDirectory (Get-HvStateDir)
    Write-HvJsonFile -Path (Join-HvPath $state 'status.json') -Value $doc
}

function Get-HvWgDumpText {
    # `wg.exe show homevault dump` - works only with administrator rights; '' when unavailable.
    if (-not (Test-HvWindows)) { return '' }
    $p = Get-HvWgPaths
    if (-not [System.IO.File]::Exists($p.WgExe)) { return '' }
    $r = Invoke-HvNative -FilePath $p.WgExe -ArgumentList @('show', $script:HvTunnelName, 'dump') -Capture -AllowFailure
    if ($r.ExitCode -ne 0) { return '' }
    return $r.Text
}

function Get-HvSystemVpnStatus {
    # Fresh output of the SYSTEM task HomeVault-VpnStatus (ProgramData\HomeVault\wireguard\vpn-status.json) or $null.
    if (-not (Test-HvWindows)) { return $null }
    $f = Join-HvPath (Get-HvWgPaths).Dir 'vpn-status.json'
    if (-not [System.IO.File]::Exists($f)) { return $null }
    $fi = New-Object System.IO.FileInfo($f)
    if ($fi.LastWriteTime -lt (Get-Date).AddMinutes(-$script:HvVpnStatusMaxAgeMin)) { return $null }
    try {
        $j = ConvertFrom-Json -InputObject ((Read-HvTextFile $f).Trim())
        if (-not (Test-HvTrue (Get-HvPropValue $j 'tunnel_ok' $false))) { return $null }
        return $j
    } catch { return $null }
}

function Update-HvVpnStatusFile {
    # Write state\vpn-status.json (VPN enabled only). Handshakes/traffic come from wg.exe when this process is
    # elevated, else from the SYSTEM task's file; otherwise only names and addresses are listed. Returns $true if written.
    $e = Get-HvEnv
    if (-not (Test-HvTrue (Get-HvEnvDictValue $e 'HV_VPN_ENABLED' 'true'))) { return $false }
    $port = 0
    [void][int]::TryParse((Get-HvEnvDictValue $e 'WG_PORT' '0'), [ref]$port)
    $doc = $null
    $dumpText = ''
    try { $dumpText = Get-HvWgDumpText } catch { $dumpText = '' }
    $peers = @()
    try { $peers = @(Get-HvPeers) } catch { $peers = @() }
    if ($dumpText) {
        $doc = New-HvVpnStatusDocument -Peers $peers -Dump (ConvertFrom-HvWgDump $dumpText) -Now (Get-Date) -ListenPort $port
    } else {
        $sys = Get-HvSystemVpnStatus
        if ($null -ne $sys) { $doc = ConvertTo-HvSanitizedVpnStatus -Object $sys -Now (Get-Date) }
        else { $doc = New-HvVpnStatusDocument -Peers $peers -Dump $null -Now (Get-Date) -ListenPort $port }
    }
    if ([int]$doc['listen_port'] -le 0) { $doc['listen_port'] = $port }
    $state = New-HvDirectory (Get-HvStateDir)
    Write-HvJsonFile -Path (Join-HvPath $state 'vpn-status.json') -Value $doc
    return $true
}

function Invoke-HvStatusUpdate {
    # hv.ps1 status-update: rewrite state\status.json (incl. disk usage), state\vpn-status.json and - in IP mode,
    # when Caddy is reachable - state\ca.crt (the panel's /ca.crt download; install runs this at the end).
    param([Parameter(ValueFromRemainingArguments = $true)][object[]]$Arguments = @())
    [void](Read-HvCommandArgs -Arguments $Arguments)
    [void](Get-HvEnv)
    Update-HvStatusFile -IncludeDisks
    if (Get-Command docker -ErrorAction SilentlyContinue) {
        try { if (Copy-HvCaToState) { Write-HvInfo '已更新 state\ca.crt（管理面板 /ca.crt 提供下载的根证书）。' } } catch { }
    }
    $vpn = $false
    try { $vpn = Update-HvVpnStatusFile } catch { Write-HvWarn ('写入 vpn-status.json 失败：' + (Get-HvErrorMessage $_)) }
    $msg = '已更新 state\status.json'
    if ($vpn) { $msg += ' 和 state\vpn-status.json' }
    Write-HvOk $msg
}
