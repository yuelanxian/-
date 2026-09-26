#Requires -Version 5.1
# Integration tests: run windows/hv.ps1 as a child process against a throwaway copy of the repo
# (install --config-only, re-install idempotence, storage add/remove, error paths). No Docker needed.
param(
    [string]$Root = (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)),
    [string]$OutDir = '',
    [switch]$UseFixtureEnvExample
)

$ErrorActionPreference = 'Stop'
if (-not $OutDir) { $OutDir = Join-Path ([System.IO.Path]::GetTempPath()) ('hv-integ-' + [guid]::NewGuid().ToString('N')) }
$pwsh = (Get-Process -Id $PID).Path
$script:Pass = 0; $script:Fail = 0
function Check { param([string]$Name, $Cond, [string]$Detail = '') if ($Cond) { $script:Pass++ } else { $script:Fail++; Write-Host ('  FAIL ' + $Name + ' ' + $Detail) } }

function New-Work {
    param([string]$Name)
    $w = Join-Path $OutDir $Name
    if (Test-Path -LiteralPath $w) { Remove-Item -LiteralPath $w -Recurse -Force }
    [void](New-Item -ItemType Directory -Path $w)
    Copy-Item -LiteralPath (Join-Path $Root 'windows') -Destination $w -Recurse
    foreach ($x in @('compose.yaml', 'compose.acme.yaml', 'caddy', 'nextcloud')) {
        $src = Join-Path $Root $x
        if (Test-Path -LiteralPath $src) { Copy-Item -LiteralPath $src -Destination $w -Recurse }
    }
    $ex = Join-Path $Root '.env.example'
    if ($UseFixtureEnvExample -or -not (Test-Path -LiteralPath $ex)) { $ex = Join-Path $Root 'tests/pwsh/fixtures/env.example' }
    Copy-Item -LiteralPath $ex -Destination (Join-Path $w '.env.example')
    foreach ($d in @('photos', 'movies', 'docs')) { [void](New-Item -ItemType Directory -Force -Path (Join-Path $w ('host/' + $d))) }
    return $w
}

function Invoke-Hv {
    param([string]$Work, [string[]]$HvArgs)
    $out = & $pwsh -NoProfile -NonInteractive -File (Join-Path $Work 'windows/hv.ps1') @HvArgs 2>&1 | Out-String
    return [pscustomobject]@{ Code = $LASTEXITCODE; Out = $out }
}

function Read-Env {
    param([string]$Work)
    $f = Join-Path $Work '.env'
    if (-not (Test-Path -LiteralPath $f)) { return [ordered]@{} }
    return (ConvertFrom-HvEnvText ([System.IO.File]::ReadAllText($f)))
}

$script:HvRoot = $Root
foreach ($lib in @(Get-ChildItem -LiteralPath (Join-Path $Root 'windows/lib') -Filter '*.ps1' | Sort-Object Name)) { . $lib.FullName }
[void](New-Item -ItemType Directory -Force -Path $OutDir)

Write-Host '-- CLI basics'
$w = New-Work 'basic'
$r = Invoke-Hv $w @('help')
Check 'help exit 0' ($r.Code -eq 0) $r.Out
Check 'help lists commands' ($r.Out.Contains('schedule-backup') -and $r.Out.Contains('vpn init'))
$r = Invoke-Hv $w @('version')
Check 'version' ($r.Code -eq 0 -and $r.Out.Contains('HomeVault'))
$r = Invoke-Hv $w @('bogus')
Check 'unknown command exit 2' ($r.Code -eq 2 -and $r.Out.Contains('未知命令')) $r.Out
$r = Invoke-Hv $w @('status')
Check 'status before install fails' ($r.Code -ne 0 -and $r.Out.Contains('install')) $r.Out
$r = Invoke-Hv $w @('install', '--bogus-flag')
Check 'unknown flag exit 2' ($r.Code -eq 2 -and $r.Out.Contains('未知参数')) $r.Out

Write-Host '-- install --config-only'
$w = New-Work 'main'
$data = Join-Path $w 'hvdata'
$bk = Join-Path $w 'backup/restic'
$photos = Join-Path $w 'host/photos'
$movies = Join-Path $w 'host/movies'
$installArgs = @('install', '--config-only', '--non-interactive', '--host', '192.168.1.10', '--lan-ip', '192.168.1.10', '--lan-cidr', '192.168.1.0/24',
    '--data-dir', $data, '--backup-target', 'local', '--backup-path', $bk, '--wg-host', 'vpn.example.com', '--wg-port', '43210',
    '--storage', ('照片|' + $photos + '|rw|yes|'), '--storage', ('影视|' + $movies + '|ro|no|@family'), '--mirror', 'daocloud')
$r = Invoke-Hv $w $installArgs
Check 'install exit 0' ($r.Code -eq 0) $r.Out
$e = Read-Env $w
Check 'platform' ($e['HV_PLATFORM'] -eq 'windows')
Check 'bind ip' ($e['HV_BIND_IP'] -eq '0.0.0.0')
Check 'site addresses' ($e['HV_SITE_ADDRESSES'] -eq 'https://192.168.1.10:443, https://10.99.77.1:443') $e['HV_SITE_ADDRESSES']
Check 'trusted domains' ($e['HV_TRUSTED_DOMAINS'] -eq '192.168.1.10 10.99.77.1')
Check 'overwrite url' ($e['HV_OVERWRITE_CLI_URL'] -eq 'https://192.168.1.10')
Check 'snippets' ($e['HV_TLS_SNIPPET'] -eq 'internal' -and $e['HV_ADMIN_SNIPPET'] -eq 'none')
Check 'nc data path' ($e['HV_NC_DATA_PATH'] -eq ($data + '/nextcloud-data')) $e['HV_NC_DATA_PATH']
Check 'dump dir' ($e['HV_DUMP_DIR'] -eq ($data + '/dumps'))
Check 'named volumes' ($e['HV_VOL_HTML'] -eq '' -and $e['HV_VOL_DB'] -eq '' -and $e['HV_VOL_CADDY_DATA'] -eq '')
Check 'vpn enabled' ($e['HV_VPN_ENABLED'] -eq 'true' -and $e['WG_PORT'] -eq '43210' -and $e['WG_HOST'] -eq 'vpn.example.com')
Check 'backup' ($e['HV_BACKUP_TARGET'] -eq 'local' -and $e['HV_BACKUP_LOCAL_PATH'] -eq $bk)
Check 'mirror' ($e['NEXTCLOUD_IMAGE'] -eq 'docker.m.daocloud.io/library/nextcloud:34-apache' -and $e['WG_EASY_IMAGE'] -like 'ghcr.m.daocloud.io/*' -and $e['HV_GOPROXY'] -eq 'https://goproxy.cn,direct')
Check 'allowed cidrs kept' ($e['HV_ALLOWED_CIDRS'] -eq 'private_ranges 100.64.0.0/10') $e['HV_ALLOWED_CIDRS']
$envText = [System.IO.File]::ReadAllText((Join-Path $w '.env'))
$exText = [System.IO.File]::ReadAllText((Join-Path $w '.env.example'))
$firstComment = (($exText -split "`n") | Where-Object { $_.StartsWith('#') } | Select-Object -First 3) -join "`n"
Check '.env keeps .env.example comments' ($envText.Contains($firstComment))
Check '.env LF only, no BOM' (-not $envText.Contains("`r") -and [System.IO.File]::ReadAllBytes((Join-Path $w '.env'))[0] -ne 0xEF)
$secretsDir = Join-Path $w 'secrets'
$sec1 = @{}
foreach ($n in @('postgres_password', 'redis_password', 'nextcloud_admin_password', 'restic_password')) {
    $f = Join-Path $secretsDir $n
    $v = ''
    if (Test-Path -LiteralPath $f) { $v = [System.IO.File]::ReadAllText($f) }
    Check ('secret ' + $n) ($v -cmatch '^[A-Za-z0-9]{32}$') $v
    $sec1[$n] = $v
}
$rows = @(ConvertFrom-HvStorageConf ([System.IO.File]::ReadAllText((Join-Path $w 'storage.conf'))))
Check 'storage rows' ($rows.Count -eq 2)
$yaml = [System.IO.File]::ReadAllText((Join-Path $w 'compose.storage.yaml'))
Check 'compose.storage.yaml' ($yaml.Contains('/mnt/hv/' + (Get-HvStorageSlug $photos)) -and $yaml.Contains('/src/storage/' + (Get-HvStorageSlug $photos)) -and -not $yaml.Contains('/src/storage/' + (Get-HvStorageSlug $movies)))
Check 'dirs created' ((Test-Path -LiteralPath ($data + '/nextcloud-data')) -and (Test-Path -LiteralPath ($data + '/dumps')) -and (Test-Path -LiteralPath $bk))

Write-Host '-- re-install is idempotent and keeps secrets'
$r = Invoke-Hv $w ($installArgs + @('--https-port', '8443'))
Check 're-install exit 0' ($r.Code -eq 0) $r.Out
$e2 = Read-Env $w
foreach ($n in $sec1.Keys) { Check ('secret kept ' + $n) ([System.IO.File]::ReadAllText((Join-Path $secretsDir $n)) -eq $sec1[$n]) }
Check 'port change applied' ($e2['HV_SITE_ADDRESSES'] -eq 'https://192.168.1.10:8443, https://10.99.77.1:8443') $e2['HV_SITE_ADDRESSES']
Check 'trusted with port' ($e2['HV_TRUSTED_DOMAINS'] -eq '192.168.1.10 192.168.1.10:8443 10.99.77.1 10.99.77.1:8443')
$envLines = @([System.IO.File]::ReadAllText((Join-Path $w '.env')) -split "`n" | Where-Object { $_ -match '^[A-Z_]+=' })
$keys = @($envLines | ForEach-Object { ($_ -split '=', 2)[0] })
Check 'no duplicate keys' ($keys.Count -eq @($keys | Select-Object -Unique).Count)
Check 'storage not duplicated' (@(ConvertFrom-HvStorageConf ([System.IO.File]::ReadAllText((Join-Path $w 'storage.conf')))).Count -eq 2)
Check 'wg port kept' ($e2['WG_PORT'] -eq '43210')

Write-Host '-- storage add / list / remove'
$docs = Join-Path $w 'host/docs'
$r = Invoke-Hv $w @('storage', 'add', '--name', '文档', '--path', $docs, '--mode', 'rw', '--backup', 'yes', '--users', 'alice,@family', '--no-apply')
Check 'storage add exit 0' ($r.Code -eq 0) $r.Out
$rows = @(ConvertFrom-HvStorageConf ([System.IO.File]::ReadAllText((Join-Path $w 'storage.conf'))))
Check 'storage added' ($rows.Count -eq 3 -and $rows[2].Name -eq '文档' -and ($rows[2].GroupList -join ',') -eq 'family')
$r = Invoke-Hv $w @('storage', 'list')
Check 'storage list' ($r.Code -eq 0 -and $r.Out.Contains('文档') -and $r.Out.Contains((Get-HvStorageSlug $docs))) $r.Out
$r = Invoke-Hv $w @('storage', 'add', '--name', '文档', '--path', $docs, '--mode', 'rw', '--backup', 'no', '--users', '', '--no-apply')
Check 'storage add duplicate fails' ($r.Code -ne 0 -and $r.Out.Contains('重复')) $r.Out
$r = Invoke-Hv $w @('storage', 'remove', '文档', '--yes', '--no-apply')
Check 'storage remove' ($r.Code -eq 0 -and @(ConvertFrom-HvStorageConf ([System.IO.File]::ReadAllText((Join-Path $w 'storage.conf')))).Count -eq 2) $r.Out
Remove-Item -LiteralPath (Join-Path $w 'compose.storage.yaml')
$r = Invoke-Hv $w @('storage', 'apply')
Check 'storage apply regenerates the overlay, then needs docker' ($r.Code -eq 127 -and (Test-Path -LiteralPath (Join-Path $w 'compose.storage.yaml'))) $r.Out

Write-Host '-- commands that need Windows / Docker fail cleanly'
$r = Invoke-Hv $w @('vpn', 'list')
Check 'vpn needs windows' ($r.Code -ne 0 -and $r.Out.Contains('Windows')) $r.Out
$r = Invoke-Hv $w @('backup')
Check 'backup without docker' ($r.Code -eq 127 -and $r.Out.Contains('docker')) $r.Out
$r = Invoke-Hv $w @('schedule-backup', '--time', '25:99')
Check 'schedule-backup validates' ($r.Code -ne 0) $r.Out

Write-Host '-- ddns setup (credentials from environment)'
$env:HV_DDNS_ID = 'LTAItest'; $env:HV_DDNS_SECRET = 'secret$with''quote'
$r = Invoke-Hv $w @('ddns', 'setup', '--provider', 'alidns', '--domain', 'home.example.com', '--non-interactive')
Remove-Item Env:\HV_DDNS_ID, Env:\HV_DDNS_SECRET
Check 'ddns setup' ($r.Code -eq 0) $r.Out
$e3 = Read-Env $w
Check 'ddns env' ($e3['HV_DDNS_ENABLED'] -eq 'true' -and $e3['HV_DDNS_DOMAIN'] -eq 'home.example.com' -and $e3['WG_HOST'] -eq 'vpn.example.com')
$dy = [System.IO.File]::ReadAllText((Join-Path $secretsDir 'ddns-go.yaml'))
Check 'ddns yaml' ($dy.Contains("secret: 'secret`$with''quote'") -and $dy.Contains("- 'home.example.com'"))

Write-Host '-- install --no-vpn / domain + acme'
$w2 = New-Work 'novpn'
$r = Invoke-Hv $w2 @('install', '--config-only', '--non-interactive', '--no-vpn', '--host', '192.168.5.20', '--lan-ip', '192.168.5.20', '--data-dir', (Join-Path $w2 'd'), '--backup-target', 'none')
Check 'no-vpn install' ($r.Code -eq 0) $r.Out
$e4 = Read-Env $w2
Check 'no-vpn values' ($e4['HV_VPN_ENABLED'] -eq 'false' -and $e4['HV_SITE_ADDRESSES'] -eq 'https://192.168.5.20:443' -and $e4['HV_LAN_CIDR'] -eq '192.168.5.0/24' -and $e4['HV_BACKUP_TARGET'] -eq 'none') ($e4['HV_SITE_ADDRESSES'] + ' ' + $e4['HV_LAN_CIDR'])
$env:ALIYUN_ACCESS_KEY_ID = 'id1'; $env:ALIYUN_ACCESS_KEY_SECRET = 'sec1'
$w3 = New-Work 'acme'
$r = Invoke-Hv $w3 @('install', '--config-only', '--non-interactive', '--host', 'cloud.example.com', '--lan-ip', '192.168.1.10', '--dns-provider', 'alidns', '--acme-email', 'a@example.com',
    '--data-dir', (Join-Path $w3 'd'), '--backup-target', 'none', '--wg-host', 'vpn.example.com')
Remove-Item Env:\ALIYUN_ACCESS_KEY_ID, Env:\ALIYUN_ACCESS_KEY_SECRET
Check 'acme install' ($r.Code -eq 0) $r.Out
$e5 = Read-Env $w3
Check 'acme values' ($e5['HV_TLS_MODE'] -eq 'acme-dns' -and $e5['HV_TLS_SNIPPET'] -eq 'acme-alidns' -and $e5['HV_SITE_ADDRESSES'] -eq 'https://cloud.example.com:443') $e5['HV_SITE_ADDRESSES']
$cd = [System.IO.File]::ReadAllText((Join-Path $w3 'secrets/caddy-dns.env'))
Check 'caddy-dns.env' ($cd -eq "ALIYUN_ACCESS_KEY_ID=id1`nALIYUN_ACCESS_KEY_SECRET=sec1`n") $cd
$w4 = New-Work 'badcidr'
$r = Invoke-Hv $w4 @('install', '--config-only', '--non-interactive', '--host', '10.99.77.5', '--lan-ip', '10.99.77.5', '--data-dir', (Join-Path $w4 'd'), '--backup-target', 'none', '--wg-host', 'x.example.com')
Check 'vpn/lan overlap rejected' ($r.Code -eq 2 -and $r.Out.Contains('重叠')) $r.Out

Write-Host ''
Write-Host ('integration tests: ' + $script:Pass + ' passed, ' + $script:Fail + ' failed')
if ($script:Fail -gt 0) { exit 1 }
exit 0
