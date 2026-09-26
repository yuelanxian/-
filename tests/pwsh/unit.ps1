#Requires -Version 5.1
# Unit tests for the pure functions of windows/lib/*.ps1 (plain assertions, no Pester).
# Artifacts for host-side validation (compose config, node QR check) are written to -OutDir.
param(
    [string]$Root = (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)),
    [string]$OutDir = ''
)

$ErrorActionPreference = 'Stop'
$script:HvRoot = $Root
foreach ($lib in @(Get-ChildItem -LiteralPath (Join-Path $Root 'windows/lib') -Filter '*.ps1' | Sort-Object Name)) { . $lib.FullName }
if (-not $OutDir) { $OutDir = Join-Path ([System.IO.Path]::GetTempPath()) ('hv-unit-' + [guid]::NewGuid().ToString('N')) }
[void](New-Item -ItemType Directory -Force -Path $OutDir)

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
    try { & $Block; $script:Fail++; Write-Host ('  FAIL ' + $Name + ' (no exception)') }
    catch {
        $m = Get-HvErrorMessage $_
        if ($m -like $Like) { $script:Pass++ } else { $script:Fail++; Write-Host ('  FAIL ' + $Name + ' (message: ' + $m + ')') }
    }
}
function Section { param([string]$T) Write-Host ('-- ' + $T) }

# ------------------------------------------------------------------ slug (vectors computed in bash)
Section 'storage slug'
$vecFile = Join-Path $OutDir 'slug-vectors.tsv'
if (Test-Path -LiteralPath $vecFile) {
    $n = 0
    foreach ($line in ([System.IO.File]::ReadAllText($vecFile, [System.Text.Encoding]::UTF8) -split "`n")) {
        if (-not $line) { continue }
        $parts = $line -split "`t"
        Assert-Eq ('slug of ' + $parts[0]) $parts[1] (Get-HvStorageSlug $parts[0])
        $n++
    }
    Assert-True 'slug vectors present' ($n -ge 3)
} else {
    Write-Host '  (slug-vectors.tsv not found - run via tests/pwsh/run.sh for the bash cross-check)'
}
Assert-Eq 'slug format' $true ((Get-HvStorageSlug 'D:\Photos') -cmatch '^s[0-9a-f]{8}$')
Assert-Eq 'slug known vector' ('s' + (Get-HvSha256Hex 'abc').Substring(0, 8)) 'sba7816bf'

# ------------------------------------------------------------------ random / hashing
Section 'random'
$r1 = New-HvRandomString 32
$r2 = New-HvRandomString 32
Assert-True 'random length 32 alnum' ($r1 -cmatch '^[A-Za-z0-9]{32}$')
Assert-True 'random differs' ($r1 -ne $r2)
Assert-True 'random custom alphabet' ((New-HvRandomString 50 'ab') -cmatch '^[ab]{50}$')
$port = Get-HvRandomPort
Assert-True 'random port range' ($port -ge 20000 -and $port -le 60000)

# ------------------------------------------------------------------ argument parsing
Section 'arguments'
$p = ConvertFrom-HvArgs -Arguments @('--data-drive', 'D', '-BackupDrive:E', '--yes', 'pos1', '--quota', [int64]536870912000, '--users', @('alice', 'bob'), '--storage', 'a|b|rw|no|', '--storage', 'c|d|ro|yes|@g', '--non-interactive') `
    -Switches @() -Options @('data-drive', 'backup-drive', 'quota', 'users') -MultiOptions @('storage')
Assert-Eq 'opt data-drive' 'D' (Get-HvOpt $p 'data-drive')
Assert-Eq 'opt -BackupDrive:E' 'E' (Get-HvOpt $p 'backup-drive')
Assert-Eq 'switch yes' $true (Test-HvOpt $p 'yes')
Assert-Eq 'switch non-interactive' $true (Test-HvOpt $p 'NonInteractive')
Assert-Eq 'positional' 'pos1' ($p.Positional -join ',')
Assert-Eq 'number arg to string' '536870912000' (Get-HvOpt $p 'quota')
Assert-Eq 'array arg joined' 'alice,bob' (Get-HvOpt $p 'users')
Assert-Eq 'multi option' 'a|b|rw|no|;c|d|ro|yes|@g' (@(Get-HvOpt $p 'storage') -join ';')
$p2 = ConvertFrom-HvArgs -Arguments @('--host=example.com', '--no-vpn') -Switches @('no-vpn') -Options @('host')
Assert-Eq 'inline value' 'example.com' (Get-HvOpt $p2 'host')
Assert-Eq 'no-vpn switch' $true (Test-HvOpt $p2 'no-vpn')
Assert-Throws 'unknown flag' { ConvertFrom-HvArgs -Arguments @('--bogus') } '*未知参数*'
Assert-Throws 'missing value' { ConvertFrom-HvArgs -Arguments @('--host') -Options @('host') } '*需要一个值*'

# ------------------------------------------------------------------ .env
Section '.env parse / write'
$envText = @"
# 注释：基本信息
COMPOSE_PROJECT_NAME=homevault
HV_HOST=192.168.1.10
HV_ALLOWED_CIDRS='private_ranges 100.64.0.0/10'
HV_EXTRA_HOSTS=
HV_R=private_ranges 10.0.0.0/8 # inline comment
export HV_EXPORTED=yes
HV_DQ="a \"q\" b"

# 派生变量
HV_SITE_ADDRESSES=https://old:443
HV_HOST=dup-should-be-dropped
"@
$vals = ConvertFrom-HvEnvText $envText
Assert-Eq 'env simple' 'homevault' $vals['COMPOSE_PROJECT_NAME']
Assert-Eq 'env single-quoted' 'private_ranges 100.64.0.0/10' $vals['HV_ALLOWED_CIDRS']
Assert-Eq 'env empty' '' $vals['HV_EXTRA_HOSTS']
Assert-Eq 'env inline comment' 'private_ranges 10.0.0.0/8' $vals['HV_R']
Assert-Eq 'env export' 'yes' $vals['HV_EXPORTED']
Assert-Eq 'env double-quoted' 'a "q" b' $vals['HV_DQ']
Assert-Eq 'env last wins' 'dup-should-be-dropped' $vals['HV_HOST']
$lines = @(Split-HvLines $envText)
$upd = [ordered]@{ HV_HOST = 'nas.example.com'; HV_SITE_ADDRESSES = 'https://nas.example.com:443, https://10.99.77.1:443'; HV_NC_DATA_PATH = 'D:\HomeVault\nextcloud-data'; HV_NEW = 'x$y' }
$out = @(Set-HvEnvLines -Lines $lines -Values $upd)
$outText = ($out -join "`n") + "`n"
Assert-True 'comments preserved' ($outText.Contains('# 注释：基本信息') -and $outText.Contains('# 派生变量'))
Assert-Eq 'updated in place (line 3)' 'HV_HOST=nas.example.com' $out[2]
Assert-Eq 'duplicate key removed' 1 (@($out | Where-Object { $_ -like 'HV_HOST=*' }).Count)
Assert-True 'appended marker' ($outText.Contains('# ---- hv.ps1'))
$back = ConvertFrom-HvEnvText $outText
Assert-Eq 'round trip windows path' 'D:\HomeVault\nextcloud-data' $back['HV_NC_DATA_PATH']
Assert-Eq 'round trip $ literal' 'x$y' $back['HV_NEW']
Assert-Eq 'round trip spaces' 'https://nas.example.com:443, https://10.99.77.1:443' $back['HV_SITE_ADDRESSES']
Assert-Eq 'untouched keys kept' 'private_ranges 100.64.0.0/10' $back['HV_ALLOWED_CIDRS']
Assert-Eq 'order kept' 'COMPOSE_PROJECT_NAME' (Get-HvEnvKeyFromLine $out[1])
$out2 = @(Set-HvEnvLines -Lines $out -Values $upd)
Assert-Eq 'idempotent rewrite' ($out -join "`n") ($out2 -join "`n")
Assert-Eq 'format plain' 'abc' (Format-HvEnvValue 'abc')
Assert-Eq 'format quoted path' "'D:\x'" (Format-HvEnvValue 'D:\x')
Assert-Eq 'format empty' '' (Format-HvEnvValue '')
Assert-Throws 'format rejects quote+special' { Format-HvEnvValue "it's a" } '*单引号*'

Section 'derived variables'
$e = [ordered]@{ HV_HOST = '192.168.1.10'; HV_LAN_IP = '192.168.1.10'; HV_HTTPS_PORT = '443'; HV_TLS_MODE = 'internal'; HV_VPN_ENABLED = 'true'; HV_VPN_CIDR = '10.99.77.0/24'; HV_EXTRA_HOSTS = 'nas.lan' }
$d = Get-HvDerivedEnv -Env $e -Platform 'windows' -WinWgDir 'C:\ProgramData\HomeVault\wireguard'
Assert-Eq 'site addresses' 'https://192.168.1.10:443, https://nas.lan:443, https://10.99.77.1:443' $d['HV_SITE_ADDRESSES']
Assert-Eq 'trusted domains' '192.168.1.10 nas.lan 10.99.77.1' $d['HV_TRUSTED_DOMAINS']
Assert-Eq 'overwrite url' 'https://192.168.1.10' $d['HV_OVERWRITE_CLI_URL']
Assert-Eq 'tls snippet' 'internal' $d['HV_TLS_SNIPPET']
Assert-Eq 'admin snippet windows' 'none' $d['HV_ADMIN_SNIPPET']
Assert-Eq 'platform' 'windows' $d['HV_PLATFORM']
Assert-Eq 'win wg dir' 'C:\ProgramData\HomeVault\wireguard' $d['HV_WIN_WG_DIR']
$e['HV_HTTPS_PORT'] = '8443'; $e['HV_EXTRA_HOSTS'] = ''
$d = Get-HvDerivedEnv -Env $e -Platform 'windows'
Assert-Eq 'site with port' 'https://192.168.1.10:8443, https://10.99.77.1:8443' $d['HV_SITE_ADDRESSES']
Assert-Eq 'trusted with port' '192.168.1.10 192.168.1.10:8443 10.99.77.1 10.99.77.1:8443' $d['HV_TRUSTED_DOMAINS']
Assert-Eq 'overwrite with port' 'https://192.168.1.10:8443' $d['HV_OVERWRITE_CLI_URL']
$e = [ordered]@{ HV_HOST = 'cloud.example.com'; HV_LAN_IP = '192.168.1.10'; HV_TLS_MODE = 'acme-dns'; HV_DNS_PROVIDER = 'tencentcloud'; HV_VPN_ENABLED = 'true'; HV_VPN_CIDR = '10.99.77.0/24' }
$d = Get-HvDerivedEnv -Env $e -Platform 'windows'
Assert-Eq 'acme: only the domain' 'https://cloud.example.com:443' $d['HV_SITE_ADDRESSES']
Assert-Eq 'acme snippet' 'acme-tencentcloud' $d['HV_TLS_SNIPPET']
$e = [ordered]@{ HV_HOST = '192.168.1.10'; HV_TLS_MODE = 'internal'; HV_VPN_ENABLED = 'false'; HV_VPN_CIDR = '10.99.77.0/24' }
$d = Get-HvDerivedEnv -Env $e -Platform 'windows' -WinWgDir 'C:\x'
Assert-Eq 'no vpn: no tunnel ip' 'https://192.168.1.10:443' $d['HV_SITE_ADDRESSES']
Assert-Eq 'no vpn: empty wg dir' '' $d['HV_WIN_WG_DIR']
$d = Get-HvDerivedEnv -Env ([ordered]@{ HV_HOST = '192.168.1.10'; HV_VPN_ENABLED = 'true' }) -Platform 'linux'
Assert-Eq 'linux admin snippet' 'wgeasy' $d['HV_ADMIN_SNIPPET']

Section 'mirror'
$pref = Get-HvMirrorPrefixes 'daocloud'
Assert-Eq 'mirror hub' 'docker.m.daocloud.io/library/nextcloud:34-apache' (Get-HvMirroredImage 'NEXTCLOUD_IMAGE' 'docker.io/library/nextcloud:34-apache' $pref)
Assert-Eq 'mirror ghcr' 'ghcr.m.daocloud.io/wg-easy/wg-easy:15' (Get-HvMirroredImage 'WG_EASY_IMAGE' 'ghcr.io/wg-easy/wg-easy:15' $pref)
Assert-Eq 'mirror implicit hub' 'docker.m.daocloud.io/library/redis:8-alpine' (Get-HvMirroredImage 'REDIS_IMAGE' 'redis:8-alpine' $pref)
Assert-Eq 'mirror local image untouched' 'homevault/caddy-dns:2.11.4' (Get-HvMirroredImage 'CADDY_DNS_IMAGE' 'homevault/caddy-dns:2.11.4' $pref)
$none = Get-HvMirrorPrefixes 'none'
Assert-Eq 'mirror back to docker.io' 'docker.io/restic/restic:0.19.1' (Get-HvMirroredImage 'RESTIC_IMAGE' 'docker.m.daocloud.io/restic/restic:0.19.1' $none)
$ch = Get-HvMirrorEnvChanges -Env ([ordered]@{ NEXTCLOUD_IMAGE = 'docker.io/library/nextcloud:34-apache'; HV_HOST = 'x' }) -Prefixes $pref
Assert-Eq 'mirror goproxy' 'https://goproxy.cn,direct' $ch['HV_GOPROXY']
Assert-True 'mirror only images' (-not $ch.Contains('HV_HOST'))
Assert-Throws 'mirror custom requires prefixes' { Get-HvMirrorPrefixes 'custom' } '*custom*'

# ------------------------------------------------------------------ network
Section 'IPv4 / CIDR'
Assert-True 'ipv4 ok' (Test-HvIPv4 '192.168.1.10')
Assert-True 'ipv4 bad' (-not (Test-HvIPv4 '192.168.1.256'))
Assert-Eq 'cidr normalise' '192.168.1.0/24' (Get-HvCidrInfo '192.168.1.77/24').Cidr
Assert-Eq 'network cidr' '10.0.0.0/8' (Get-HvNetworkCidr '10.2.3.4' 8)
Assert-Eq 'vpn server ip' '10.99.77.1' (Get-HvVpnServerIp '10.99.77.0/24')
Assert-True 'ip in cidr' (Test-HvIpInCidr '10.99.77.200' '10.99.77.0/24')
Assert-True 'ip not in cidr' (-not (Test-HvIpInCidr '10.99.78.1' '10.99.77.0/24'))
Assert-True 'overlap' (Test-HvCidrOverlap '10.0.0.0/8' '10.99.77.0/24')
Assert-True 'no overlap' (-not (Test-HvCidrOverlap '192.168.1.0/24' '10.99.77.0/24'))
Assert-Eq 'next free ip (empty)' '10.99.77.2' (Get-HvNextFreeIp '10.99.77.0/24' @('10.99.77.1'))
Assert-Eq 'next free ip (gap)' '10.99.77.3' (Get-HvNextFreeIp '10.99.77.0/24' @('10.99.77.1', '10.99.77.2/32', '10.99.77.4'))
Assert-Throws 'pool exhausted' { Get-HvNextFreeIp '10.99.77.0/30' @('10.99.77.1', '10.99.77.2') } '*没有可分配*'
Assert-Eq 'complement' '0.0.0.0-9.255.255.255|11.0.0.0-192.168.0.255|192.168.2.0-255.255.255.255' ((Get-HvIPv4Complement @('192.168.1.0/24', '10.0.0.0/8')) -join '|')
Assert-Eq 'complement single' '0.0.0.0-10.99.76.255|10.99.78.0-255.255.255.255' ((Get-HvIPv4Complement @('10.99.77.0/24')) -join '|')
Assert-Eq 'endpoint v4' 'vpn.example.com:51820' (Format-HvEndpoint 'vpn.example.com' '51820')
Assert-Eq 'endpoint v6' '[2001:db8::1]:51820' (Format-HvEndpoint '2001:db8::1' '51820')
Assert-True 'domain' (Test-HvDomainName 'cloud.example.com')
Assert-True 'domain rejects ip' (-not (Test-HvDomainName '192.168.1.10'))
Assert-True 'hostname single label' (Test-HvHostName 'nas')

# ------------------------------------------------------------------ storage.conf
Section 'storage.conf'
$conf = @"
# 名称|主机路径|rw或ro|是否备份(yes/no)|可见用户
照片归档|D:\Photos|rw|no|
影视资料 | E:\Movies | RO | yes | @family, alice
"@
$rows = @(ConvertFrom-HvStorageConf $conf)
Assert-Eq 'rows' 2 $rows.Count
Assert-Eq 'row name' '照片归档' $rows[0].Name
Assert-Eq 'row slug' (Get-HvStorageSlug 'D:\Photos') $rows[0].Slug
Assert-Eq 'row trimmed path' 'E:\Movies' $rows[1].Path
Assert-Eq 'row ro' $true $rows[1].ReadOnly
Assert-Eq 'row backup' $true $rows[1].Backup
Assert-Eq 'row groups' 'family' ($rows[1].GroupList -join ',')
Assert-Eq 'row users' 'alice' ($rows[1].UserList -join ',')
Assert-Throws 'bad mode' { ConvertFrom-HvStorageConf 'a|D:\x|rx|no|' } '*第 1 行*rw*'
Assert-Throws 'bad backup' { ConvertFrom-HvStorageConf 'a|D:\x|rw|maybe|' } '*yes 或 no*'
Assert-Throws 'dup name' { ConvertFrom-HvStorageConf "a|D:\x|rw|no|`na|D:\y|rw|no|" } '*名称重复*'
Assert-Throws 'dup path' { ConvertFrom-HvStorageConf "a|D:\x|rw|no|`nb|D:\x|ro|no|" } '*重复*'
Assert-Throws 'too few fields' { ConvertFrom-HvStorageConf 'a|D:\x|rw' } '*格式错误*'
Assert-Throws 'bad name' { ConvertFrom-HvStorageConf 'a/b|D:\x|rw|no|' } '*名称无效*'
$added = Add-HvStorageConfLine -Text $conf -Line (ConvertTo-HvStorageConfLine -Name '文档' -Path 'F:\Docs' -Mode 'rw' -Backup 'yes' -Users '')
Assert-Eq 'add row' 3 @(ConvertFrom-HvStorageConf $added).Count
$removed = Remove-HvStorageConfLine -Text $added -Name '照片归档'
Assert-True 'remove keeps comments' ($removed.Contains('# 名称|主机路径'))
Assert-Eq 'remove row' '影视资料,文档' ((@(ConvertFrom-HvStorageConf $removed) | ForEach-Object { $_.Name }) -join ',')
Assert-Throws 'remove missing' { Remove-HvStorageConfLine -Text $conf -Name 'nope' } '*没有名为*'
Assert-True 'header parses' (@(ConvertFrom-HvStorageConf (Get-HvStorageConfHeader)).Count -eq 0)

Section 'compose.storage.yaml'
$yaml = ConvertTo-HvComposeStorageYaml -Rows $rows
Assert-True 'yaml app' ($yaml.Contains("services:`n  app:`n    volumes:"))
Assert-True 'yaml cron' ($yaml.Contains("  cron:`n    volumes:"))
Assert-True 'yaml quoted windows path' ($yaml.Contains("source: 'D:\Photos'"))
Assert-True 'yaml target' ($yaml.Contains('target: /mnt/hv/' + $rows[0].Slug))
Assert-True 'yaml ro' ($yaml.Contains("target: /mnt/hv/" + $rows[1].Slug + "`n        read_only: true"))
Assert-True 'yaml backup only backup=yes' ($yaml.Contains('/src/storage/' + $rows[1].Slug) -and -not $yaml.Contains('/src/storage/' + $rows[0].Slug))
Assert-Eq 'yaml empty' $true ((ConvertTo-HvComposeStorageYaml -Rows @()).Contains('services: {}'))
Assert-Eq 'yaml single quote escaping' "'/tmp/it''s'" (ConvertTo-HvYamlSingleQuoted "/tmp/it's")
# artifacts for `docker compose config` on the host (Linux-style and Windows-style paths)
$linuxConf = @"
照片|/tmp/hv-test/照片|rw|yes|
it's|/tmp/hv-test/it's dir|ro|no|@family
影视|/tmp/hv-test/movies|ro|yes|alice,bob
"@
$linuxRows = @(ConvertFrom-HvStorageConf $linuxConf)
$linuxPanel = @(Get-HvPanelStatMounts -Rows $linuxRows -StorageConfPath '/tmp/hv-test/storage.conf' -NcDataPath '/tmp/hv-test/nc-data' -BackupPath '/tmp/hv-test/backup' -StateDir '/tmp/hv-test/state')
Write-HvTextFile -Path (Join-Path $OutDir 'compose.storage.linux.yaml') -Content (ConvertTo-HvComposeStorageYaml -Rows $linuxRows -PanelMounts $linuxPanel)
$winPanel = @(Get-HvPanelStatMounts -Rows $rows -StorageConfPath 'C:\HomeVault\storage.conf' -NcDataPath 'D:\HomeVault\nextcloud-data' -BackupPath 'E:\HomeVault-Backup\restic')
Write-HvTextFile -Path (Join-Path $OutDir 'compose.storage.windows.yaml') -Content (ConvertTo-HvComposeStorageYaml -Rows $rows -PanelMounts $winPanel)
Write-HvTextFile -Path (Join-Path $OutDir 'compose.storage.empty.yaml') -Content (ConvertTo-HvComposeStorageYaml -Rows @())
Write-HvTextFile -Path (Join-Path $OutDir 'compose.storage.panelonly.yaml') -Content (ConvertTo-HvComposeStorageYaml -Rows @() -PanelMounts @(Get-HvPanelStatMounts -NcDataPath 'D:\HomeVault\nextcloud-data'))
Assert-Eq 'panel stat targets' ('/config/storage.conf|/stat/data|/stat/backup|/stat/storage/' + $rows[0].Slug + '|/stat/storage/' + $rows[1].Slug) (($winPanel | ForEach-Object { $_.Target }) -join '|')
Assert-Eq 'panel stat vector (D:\Photos -> sea173462)' '/stat/storage/sea173462' $winPanel[3].Target
Assert-Eq 'panel stat without backup/conf' '/stat/data' ((@(Get-HvPanelStatMounts -NcDataPath 'D:\x') | ForEach-Object { $_.Target }) -join '|')
$wy = ConvertTo-HvComposeStorageYaml -Rows $rows -PanelMounts $winPanel
Assert-True 'yaml panel section' ($wy.Contains("  panel:`n    volumes:`n"))
Assert-True 'yaml panel stat data ro' ($wy.Contains("source: 'D:\HomeVault\nextcloud-data'`n        target: /stat/data`n        read_only: true"))
Assert-True 'yaml panel storage.conf' ($wy.Contains("target: /config/storage.conf`n        read_only: true"))
Assert-True 'yaml panel storage ro even if rw' ($wy.Contains("target: /stat/storage/" + $rows[0].Slug + "`n        read_only: true"))
Assert-True 'yaml panel only' ((ConvertTo-HvComposeStorageYaml -Rows @() -PanelMounts @(Get-HvPanelStatMounts -NcDataPath 'D:\x')) -match "services:`n  panel:`n")
$slugList = $linuxRows | ForEach-Object { $_.Slug + "`t" + $_.Path + "`t" + $_.Mode + "`t" + $_.Backup }
Write-HvTextFile -Path (Join-Path $OutDir 'compose.storage.linux.expect') -Content (($slugList -join "`n") + "`n")

Section 'files_external plan'
$listJson = @'
Some warning line
[{"mount_id":1,"mount_point":"\/照片归档","storage":"\\OC\\Files\\Storage\\Local","authentication_type":"null::null","configuration":{"datadir":"\/mnt\/hv/SLUG0"},"options":{"readonly":true},"applicable_users":["bob"],"applicable_groups":[]},
 {"mount_id":2,"mount_point":"\/old","storage":"\\OC\\Files\\Storage\\Local","authentication_type":"null::null","configuration":{"datadir":"\/mnt\/hv\/s00000000"},"options":[],"applicable_users":[],"applicable_groups":[]},
 {"mount_id":3,"mount_point":"\/manual","storage":"\\OC\\Files\\Storage\\Local","authentication_type":"null::null","configuration":{"datadir":"\/srv\/other"},"options":[],"applicable_users":[],"applicable_groups":[]},
 {"mount_id":4,"mount_point":"\/旧名字","storage":"\\OC\\Files\\Storage\\Local","authentication_type":"null::null","configuration":{"datadir":"\/mnt\/hv\/SLUG1"},"options":{"readonly":true,"filesystem_check_changes":1},"applicable_users":[],"applicable_groups":["family"]}]
'@
$listJson = $listJson.Replace('SLUG0', $rows[0].Slug).Replace('SLUG1', $rows[1].Slug)
$cur = @(ConvertFrom-HvMountListJson $listJson)
Assert-Eq 'mount list parsed' 4 $cur.Count
Assert-Eq 'mount datadir' ('/mnt/hv/' + $rows[0].Slug) $cur[0].DataDir
Assert-Eq 'mount readonly' $true $cur[0].ReadOnly
Assert-Eq 'mount users' 'bob' ($cur[0].Users -join ',')
Assert-Eq 'mount empty options' '' $cur[1].CheckChanges
$plan = @(Get-HvMountPlan -Desired $rows -Current $cur)
$summary = ($plan | ForEach-Object { $_.Type + ':' + [string]$_.Name }) -join ';'
Assert-Eq 'plan' ('update:照片归档;delete:/旧名字;create:影视资料;delete:/old') $summary
$u = $plan[0]
Assert-Eq 'update readonly false' 'false' $u.Options['readonly']
Assert-Eq 'update check changes' '1' $u.Options['filesystem_check_changes']
Assert-Eq 'update remove-all (all users)' $true $u.RemoveAll
Assert-Eq 'applicable args' 'files_external:applicable|1|--remove-all' ((Get-HvMountApplicableArgs $u) -join '|')
Assert-Eq 'create args' ('files_external:create|/影视资料|local|null::null|-c|datadir=/mnt/hv/' + $rows[1].Slug + '|--applicable-user|alice|--applicable-group|family') ((Get-HvMountCreateArgs $plan[2].Row) -join '|')
Assert-True 'unmanaged mount untouched' (-not ($plan | Where-Object { $_.Type -eq 'delete' -and $_.Id -eq 3 }))
$same = @(Get-HvMountPlan -Desired @($rows[0]) -Current @([pscustomobject]@{ Id = 9; MountPoint = '/照片归档'; DataDir = ('/mnt/hv/' + $rows[0].Slug); ReadOnly = $false; CheckChanges = '1'; Users = @(); Groups = @() }))
Assert-Eq 'plan idempotent' 0 $same.Count
$upd2 = Get-HvMountUpdate -Row $rows[1] -Current ([pscustomobject]@{ Id = 5; ReadOnly = $true; CheckChanges = '1'; Users = @('carol'); Groups = @() })
Assert-Eq 'applicable diff' 'files_external:applicable|5|--add-user|alice|--remove-user|carol|--add-group|family' ((Get-HvMountApplicableArgs $upd2) -join '|')
Assert-Eq 'empty list' 0 @(ConvertFrom-HvMountListJson '[]').Count
Assert-Eq 'no json' 0 @(ConvertFrom-HvMountListJson 'No admin mounts configured').Count

# ------------------------------------------------------------------ disks / tables
Section 'disks and tables'
$disks = @(
    [pscustomobject]@{ Letter = 'C'; Label = '系统'; FileSystem = 'NTFS'; SizeBytes = 500GB; FreeBytes = 100GB; DiskNumber = '0'; Media = 'SSD'; IsSystem = $true; IsSysDisk = $true; IsUsb = $false; BitLocker = 'On' },
    [pscustomobject]@{ Letter = 'D'; Label = '数据'; FileSystem = 'NTFS'; SizeBytes = 2TB; FreeBytes = 1.5TB; DiskNumber = '0'; Media = 'SSD'; IsSystem = $false; IsSysDisk = $true; IsUsb = $false; BitLocker = 'Off' },
    [pscustomobject]@{ Letter = 'E'; Label = 'Backup'; FileSystem = 'exFAT'; SizeBytes = 4TB; FreeBytes = 3TB; DiskNumber = '1'; Media = 'HDD'; IsSystem = $false; IsSysDisk = $false; IsUsb = $true; BitLocker = '-' },
    [pscustomobject]@{ Letter = 'F'; Label = ''; FileSystem = 'NTFS'; SizeBytes = 4TB; FreeBytes = 3.9TB; DiskNumber = '2'; Media = 'HDD'; IsSystem = $false; IsSysDisk = $false; IsUsb = $true; BitLocker = '-' }
)
$tbl = @(Format-HvDiskTable $disks)
Assert-Eq 'table rows' 6 $tbl.Count
Assert-True 'table header' ($tbl[0] -match '^盘符\s*\|\s*卷标\s*\|\s*文件系统\s*\|')
Assert-Eq 'display width cjk' 4 (Get-HvDisplayWidth '中文')
Assert-Eq 'display width mixed' 5 (Get-HvDisplayWidth 'a中文')
$posD = $tbl[3].IndexOf('| NTFS'); $posE = $tbl[4].IndexOf('| exFAT')
Assert-True 'columns aligned by display width' ((Get-HvDisplayWidth $tbl[3].Substring(0, $posD)) -eq (Get-HvDisplayWidth $tbl[4].Substring(0, $posE)))
Assert-Eq 'size text' '2.0 TB' (ConvertTo-HvSizeText 2TB)
Assert-Eq 'size text MB' '1.5 MB' (ConvertTo-HvSizeText 1572864)
Assert-Eq 'default data disk' 'D' (Get-HvDefaultDataDisk $disks).Letter
$wsys = @(Get-HvDiskWarnings -Disk $disks[0] -Role 'primary')
Assert-True 'warn system drive' ($wsys.Count -eq 1 -and $wsys[0] -like '*系统盘*')
$wex = @(Get-HvDiskWarnings -Disk $disks[2] -Role 'primary')
Assert-True 'warn exfat + usb' ($wex.Count -eq 2)
$bw = @(Get-HvBackupDiskWarnings -BackupDisk $disks[1] -PrimaryDisk $disks[0])
Assert-True 'warn same physical disk' ($bw.Count -eq 1 -and $bw[0] -like '*同一块物理磁盘*')
Assert-Eq 'no warn other disk' 0 @(Get-HvBackupDiskWarnings -BackupDisk $disks[3] -PrimaryDisk $disks[1]).Count
Assert-Eq 'warn rw storage disk' 1 @(Get-HvBackupDiskWarnings -BackupDisk $disks[3] -PrimaryDisk $disks[1] -RwStorageDisks @($disks[3])).Count
Assert-Eq 'find disk' 'E' (Find-HvDisk $disks 'e:').Letter
Assert-Eq 'drive from path' 'D' (Get-HvDriveLetterFromPath 'd:\HomeVault')
Assert-True 'abs path' (Test-HvWindowsAbsPath 'E:\Photos')
Assert-True 'not abs path' (-not (Test-HvWindowsAbsPath 'Photos'))

# ------------------------------------------------------------------ WireGuard
Section 'WireGuard'
Assert-True 'peer name ok' (Test-HvPeerName 'phone-zhang')
Assert-True 'peer name too long' (-not (Test-HvPeerName 'abcdefghijklmnop'))
Assert-True 'peer name chinese rejected' (-not (Test-HvPeerName '手机'))
$peers = @(
    [pscustomobject]@{ name = 'phone1'; publicKey = 'PUB1='; presharedKey = 'PSK1='; address = '10.99.77.2'; created = '2026-09-26T10:00:00' },
    [pscustomobject]@{ name = 'laptop'; publicKey = 'PUB2='; presharedKey = ''; address = '10.99.77.3'; created = '2026-09-26T11:00:00' }
)
$srv = New-HvWgServerConf -PrivateKey 'SRVPRIV=' -Address '10.99.77.1/24' -ListenPort '43210' -Peers $peers
$expected = @(
    '# 由 HomeVault 管理（.\windows\hv.ps1 vpn ...），请勿手工编辑。', '[Interface]', 'PrivateKey = SRVPRIV=', 'Address = 10.99.77.1/24', 'ListenPort = 43210', '',
    '# phone1 (2026-09-26T10:00:00)', '[Peer]', 'PublicKey = PUB1=', 'PresharedKey = PSK1=', 'AllowedIPs = 10.99.77.2/32', '',
    '# laptop (2026-09-26T11:00:00)', '[Peer]', 'PublicKey = PUB2=', 'AllowedIPs = 10.99.77.3/32') -join "`n"
Assert-Eq 'server conf' ($expected + "`n") $srv
$cli = New-HvWgClientConf -PrivateKey 'CPRIV=' -Address '10.99.77.2' -Dns '223.5.5.5,119.29.29.29' -ServerPublicKey 'SPUB=' -PresharedKey 'PSK1=' `
    -Endpoint 'vpn.example.com:43210' -AllowedIPs (Get-HvWgClientAllowedIPs '10.99.77.1' '192.168.1.10') -Keepalive '0'
$expectedCli = @('[Interface]', 'PrivateKey = CPRIV=', 'Address = 10.99.77.2/32', 'DNS = 223.5.5.5, 119.29.29.29', '', '[Peer]', 'PublicKey = SPUB=',
    'PresharedKey = PSK1=', 'Endpoint = vpn.example.com:43210', 'AllowedIPs = 10.99.77.1/32, 192.168.1.10/32') -join "`n"
Assert-Eq 'client conf (keepalive 0 omitted)' ($expectedCli + "`n") $cli
$cli25 = New-HvWgClientConf -PrivateKey 'C=' -Address '10.99.77.9' -Dns '' -ServerPublicKey 'S=' -PresharedKey '' -Endpoint 'h:1' -AllowedIPs '10.99.77.1/32' -Keepalive '25'
Assert-True 'client keepalive 25' ($cli25.Contains('PersistentKeepalive = 25'))
Assert-True 'client no dns when empty' (-not $cli25.Contains('DNS ='))
Assert-True 'client no psk when empty' (-not $cli25.Contains('PresharedKey'))
Assert-Eq 'allowed ips dedupe' '10.99.77.1/32' (Get-HvWgClientAllowedIPs '10.99.77.1' '10.99.77.1')
$json = ConvertTo-HvPeersJson $peers
$back = @(ConvertFrom-HvPeersJson $json)
Assert-Eq 'peers json round trip' 'phone1|10.99.77.2|PSK1=;laptop|10.99.77.3|' (($back | ForEach-Object { $_.name + '|' + $_.address + '|' + $_.presharedKey }) -join ';')
Assert-Eq 'peers json empty' "[]`n" (ConvertTo-HvPeersJson @())
Assert-Eq 'peers json single' 1 @(ConvertFrom-HvPeersJson (ConvertTo-HvPeersJson @($peers[0]))).Count
Assert-True 'peers json has no private key field' (-not $json.Contains('privateKey'))
$used = @('10.99.77.1') + @($back | ForEach-Object { $_.address })
Assert-Eq 'allocate after peers' '10.99.77.4' (Get-HvNextFreeIp '10.99.77.0/24' $used)

Section 'QR page'
$tpl = [System.IO.File]::ReadAllText((Join-Path $Root 'windows/templates/vpn-qr.html'))
$qrjs = [System.IO.File]::ReadAllText((Join-Path $Root 'windows/vendor/qrcode.js'))
$html = Get-HvQrPageHtml -Template $tpl -QrJs $qrjs -ConfigText ($cli + "# </script><b>x</b>`n") -PeerName 'phone1' -Endpoint 'vpn.example.com:43210' -Address '10.99.77.2' -GeneratedAt '2026-09-26 10:00'
Assert-True 'placeholders replaced' (-not ($html -match '\{\{HV_[A-Z_]+\}\}'))
Assert-True 'script injection escaped' (-not $html.Contains('# </script>'))
Assert-True 'qrcode inlined' ($html.Contains('var qrcode = function()'))
Assert-True 'config json inlined' ($html.Contains('"[Interface]\nPrivateKey = CPRIV=\n'))
Assert-True 'filename json' ($html.Contains('"phone1.conf"'))
Write-HvTextFile -Path (Join-Path $OutDir 'vpn-qr.html') -Content $html
Write-HvTextFile -Path (Join-Path $OutDir 'vpn-qr.expected.conf') -Content ($cli + "# </script><b>x</b>`n")
Assert-Eq 'json string escaping' '"a\"b\\c\n\u003c/x\u003e\u0026"' (ConvertTo-HvJsonString "a`"b\c`n</x>&")

# ------------------------------------------------------------------ backup / restic
Section 'restic arguments'
$be = [ordered]@{ HV_BACKUP_TARGET = 'local'; HV_BACKUP_KEEP_DAILY = '7'; HV_BACKUP_KEEP_WEEKLY = '4'; HV_BACKUP_KEEP_MONTHLY = '12' }
Assert-Eq 'repo local' '-r|/repo' ((Get-HvResticRepoArgs $be) -join '|')
$s3 = [ordered]@{ HV_BACKUP_TARGET = 's3'; HV_BACKUP_S3_REPO = 's3:https://oss-cn-hongkong.aliyuncs.com/b/hv'; HV_BACKUP_S3_OPTIONS = '-o s3.bucket-lookup=dns  -o s3.region=oss-cn-hongkong' }
Assert-Eq 'repo s3' '-r|s3:https://oss-cn-hongkong.aliyuncs.com/b/hv|-o|s3.bucket-lookup=dns|-o|s3.region=oss-cn-hongkong' ((Get-HvResticRepoArgs $s3) -join '|')
Assert-Throws 'repo none' { Get-HvResticRepoArgs ([ordered]@{ HV_BACKUP_TARGET = 'none' }) } '*未配置备份目标*'
$paths = @(Get-HvBackupPaths -Storages $rows -WinWireGuard $true)
Assert-Eq 'backup paths' ('/src/nextcloud-html/config|/src/nextcloud-html/custom_apps|/src/nextcloud-html/themes|/src/nextcloud-data|/src/caddy-data|/src/dumps|/src/project|/src/windows-wireguard|/src/storage/' + $rows[1].Slug) ($paths -join '|')
$ba = (Get-HvResticBackupArgs -Env $be -Paths @('/src/dumps')) -join ' '
Assert-Eq 'backup args' '-r /repo backup /src/dumps --tag homevault --host homevault --exclude /src/nextcloud-data/appdata_*/preview --exclude /src/nextcloud-data/*.log --exclude /src/project/.git --exclude /src/project/restore --exclude /src/project/state/backup.lock' $ba
Assert-Eq 'forget args' '-r /repo forget --tag homevault --group-by host,tags --keep-daily 7 --keep-weekly 4 --keep-monthly 12 --prune' ((Get-HvResticForgetArgs $be) -join ' ')
Assert-Eq 'check args' '-r /repo check --read-data-subset=5%' ((Get-HvResticCheckArgs $be) -join ' ')
Assert-Eq 'task time' '03:30' (ConvertTo-HvTaskTime '3:30').ToString('HH:mm')
Assert-Throws 'task time invalid' { ConvertTo-HvTaskTime '25:00' } '*无效时间*'
$now = [datetime]::new(2026, 9, 26, 12, 0, 0, [System.DateTimeKind]::Utc)
Assert-Eq 'backup age' 12 ([int](Get-HvBackupAgeHours '2026-09-26T00:00:00.0000000Z' $now))
Assert-Eq 'backup age invalid' $null (Get-HvBackupAgeHours 'garbage' $now)
Assert-True 'restore overlay rw' ((New-HvRestoreOverlay).Contains('${HV_NC_DATA_PATH}:/src/nextcloud-data') -and -not (New-HvRestoreOverlay).Contains(':ro'))
Write-HvTextFile -Path (Join-Path $OutDir 'compose.restore.yaml') -Content (New-HvRestoreOverlay)

Section 'restore --full database'
$sql = New-HvRestoreDbSql -User 'oc_hvadmin' -Password "p'w" -Name 'nextcloud'
$sqlExpected = @(
    'DO $hv$BEGIN IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = ''oc_hvadmin'') THEN CREATE ROLE "oc_hvadmin" LOGIN PASSWORD ''p''''w''; ELSE ALTER ROLE "oc_hvadmin" WITH LOGIN PASSWORD ''p''''w''; END IF; END$hv$;',
    'DROP DATABASE IF EXISTS "nextcloud" WITH (FORCE);',
    'CREATE DATABASE "nextcloud" OWNER "oc_hvadmin";') -join "`n"
Assert-Eq 'restore sql (role + db)' ($sqlExpected + "`n") $sql
Assert-Eq 'restore sql for the superuser itself' ("DROP DATABASE IF EXISTS `"nextcloud`" WITH (FORCE);`nCREATE DATABASE `"nextcloud`" OWNER `"nextcloud`";`n") (New-HvRestoreDbSql -User 'nextcloud' -Password 'x' -Name 'nextcloud')
Assert-Throws 'restore sql rejects odd role names' { New-HvRestoreDbSql -User 'x"; DROP' -Password '' -Name 'nextcloud' } '*格式异常*'
$dbc = ConvertFrom-HvDbConfigOutput -Lines @('Some PHP warning', 'oc_hvadmin', 'secretPW', "nextcloud`r")
Assert-Eq 'db config from php output' 'oc_hvadmin|secretPW|nextcloud' ($dbc.User + '|' + $dbc.Password + '|' + $dbc.Name)
Assert-Throws 'db config incomplete' { ConvertFrom-HvDbConfigOutput -Lines @('', 'x', '') } '*config.php*'
$dumpOk = Join-Path $OutDir 'dump-ok.sql'
Write-HvTextFile -Path $dumpOk -Content (('-- x' + "`n") * 3000 + "--`n-- PostgreSQL database dump complete`n--`n")
$dumpBad = Join-Path $OutDir 'dump-bad.sql'
Write-HvTextFile -Path $dumpBad -Content "--`n-- PostgreSQL database dump`n--`nCREATE TABLE x (a int);`n"
Assert-True 'dump complete' (Test-HvDumpComplete $dumpOk)
Assert-True 'dump truncated' (-not (Test-HvDumpComplete $dumpBad))

# ------------------------------------------------------------------ firewall / doctor / misc
Section 'firewall / doctor / misc'
$fe = [ordered]@{ HV_HTTP_PORT = '80'; HV_HTTPS_PORT = '443'; HV_LAN_CIDR = '192.168.1.0/24'; HV_VPN_ENABLED = 'true'; HV_VPN_CIDR = '10.99.77.0/24'; WG_PORT = '43210' }
$specs = @(Get-HvFirewallRuleSpecs -Env $fe)
Assert-Eq 'fw rule names' 'HomeVault-HTTPS|HomeVault-Block-Other|HomeVault-Block-IPv6|HomeVault-WireGuard' (($specs | ForEach-Object { $_.Name }) -join '|')
Assert-Eq 'fw https remote' '192.168.1.0/24|10.99.77.0/24' ($specs[0].RemoteAddress -join '|')
Assert-Eq 'fw ports (http, https, admin, panel)' '80|443|8443|9443' ($specs[0].LocalPort -join '|')
Assert-Eq 'fw block covers panel port' '80|443|8443|9443' ($specs[1].LocalPort -join '|')
$fe2 = [ordered]@{ HV_HTTP_PORT = '80'; HV_HTTPS_PORT = '443'; HV_ADMIN_PORT = '443'; HV_PANEL_PORT = '19443'; HV_LAN_CIDR = '192.168.1.0/24'; HV_VPN_ENABLED = 'false' }
Assert-Eq 'fw ports dedupe + custom panel port' '80|443|19443' ((@(Get-HvFirewallRuleSpecs -Env $fe2))[0].LocalPort -join '|')
Assert-Eq 'fw block complement (loopback excluded)' '0.0.0.0-10.99.76.255|10.99.78.0-126.255.255.255|128.0.0.0-192.168.0.255|192.168.2.0-255.255.255.255' ($specs[1].RemoteAddress -join '|')
Assert-Eq 'fw wg port' '43210' ($specs[3].LocalPort -join '|')
$fe['HV_VPN_ENABLED'] = 'false'
Assert-Eq 'fw no vpn' 'HomeVault-HTTPS|HomeVault-Block-Other|HomeVault-Block-IPv6' ((@(Get-HvFirewallRuleSpecs -Env $fe) | ForEach-Object { $_.Name }) -join '|')
$psJson = '{"Service":"caddy","State":"running","Health":"healthy","Publishers":[{"URL":"0.0.0.0","TargetPort":443,"PublishedPort":443,"Protocol":"tcp"},{"URL":"::","TargetPort":80,"PublishedPort":80,"Protocol":"tcp"}]}' + "`n" +
'{"Service":"app","State":"running","Health":"healthy","Publishers":[{"URL":"0.0.0.0","TargetPort":80,"PublishedPort":8080,"Protocol":"tcp"},{"URL":"","TargetPort":9000,"PublishedPort":0,"Protocol":"tcp"}]}'
$psRows = @(ConvertFrom-HvJsonArrayText $psJson)
Assert-Eq 'ndjson rows' 2 $psRows.Count
Assert-Eq 'json array rows' 2 @(ConvertFrom-HvJsonArrayText ('[' + ($psJson -replace "`n", ',') + ']')).Count
$issues = @(Get-HvPublisherIssues -Rows $psRows -BindIp '0.0.0.0' -AllowedTcpPorts @('80', '443'))
Assert-Eq 'publisher issues' 2 $issues.Count
Assert-True 'publisher ipv6 flagged' ($issues[0] -like '*IPv6*')
Assert-True 'publisher app flagged' ($issues[1] -like 'app *')
$scj = ConvertFrom-Json '{"security":{"a":{"name":"HTTPS","severity":"success"},"b":{"name":"HSTS","severity":"warning"}},"system":{"c":{"name":"PHP","severity":"error"}}}'
$sc = Get-HvSetupChecksSummary $scj
Assert-Eq 'setupchecks errors' 1 $sc.Errors
Assert-Eq 'setupchecks warnings' 'HSTS' ($sc.WarningNames -join ',')
Assert-Eq 'version compare' -1 (Compare-HvVersion '4.9.1' '4.92.0')
Assert-Eq 'version compare eq' 0 (Compare-HvVersion 'v2.24.0' '2.24')
Assert-Eq 'version compare gt' 1 (Compare-HvVersion '5.1.1' '2.24.0')
Assert-Eq 'next major' 'docker.io/library/nextcloud:35-apache' (Get-HvNextMajorImage 'docker.io/library/nextcloud:34-apache')
Assert-Eq 'next major pinned' 'reg.example:5000/library/nextcloud:35-apache' (Get-HvNextMajorImage 'reg.example:5000/library/nextcloud:34.0.4-apache')
Assert-Eq 'quota bytes' '536870912000' (ConvertTo-HvQuota '536870912000')
Assert-Eq 'quota text' '500 GB' (ConvertTo-HvQuota '500gb')
Assert-Throws 'quota invalid' { ConvertTo-HvQuota 'lots' } '*无效的配额*'
$ddns = New-HvDdnsGoYaml -Provider 'alidns' -Id 'LTAI' -Secret "s'x" -Domains @('vpn.example.com')
Assert-True 'ddns yaml' ($ddns.Contains("secret: 's''x'") -and $ddns.Contains("- 'vpn.example.com'") -and $ddns.Contains('name: alidns'))
Write-HvTextFile -Path (Join-Path $OutDir 'ddns-go.yaml') -Content $ddns
Assert-Throws 'ddns provider' { New-HvDdnsGoYaml -Provider 'foo' -Id '' -Secret 'x' -Domains @('a.b') } '*不支持*'
Assert-Eq 'icacls args' 'C:\x|/inheritance:r|/grant:r|*S-1-5-18:(OI)(CI)F|*S-1-5-32-544:(OI)(CI)F|*S-1-5-21-1:(OI)(CI)RX|*S-1-5-21-2:(OI)(CI)RX|/Q' ((Get-HvIcaclsArgs -Path 'C:\x' -UserSids @('S-1-5-21-1', 'S-1-5-21-2') -Directory -UserReadOnly) -join '|')
Assert-Eq 'icacls file args' 'C:\f|/inheritance:r|/grant:r|*S-1-5-18:F|*S-1-5-32-544:F|*S-1-5-21-1:F|/Q' ((Get-HvIcaclsArgs -Path 'C:\f' -UserSids @('S-1-5-21-1')) -join '|')
Assert-Eq 'cmdline quoting' 'a "b c" "d\"e" "f g\\" "" h\' (ConvertTo-HvCommandLine @('a', 'b c', 'd"e', 'f g\', '', 'h\'))
Assert-Eq 'cmdline backslash before quote' '"x\\\"y z"' (ConvertTo-HvCommandLineArg 'x\"y z')
Assert-Eq 'legacy native arg quote' 'd\"e' (ConvertTo-HvNativeArg -Arg 'd"e' -Legacy $true)
Assert-Eq 'legacy native empty' '""' (ConvertTo-HvNativeArg -Arg '' -Legacy $true)
Assert-Eq 'modern native passthrough' 'd"e' (ConvertTo-HvNativeArg -Arg 'd"e' -Legacy $false)
Assert-Eq 'json slice' '{"a":1}' (Get-HvJsonSlice "warn`n{`"a`":1}`ntrailer")
Assert-Eq 'env file text' "A=1`nB='x y'`n" (ConvertTo-HvEnvFileText ([ordered]@{ A = '1'; B = 'x y' }))

# ------------------------------------------------------------------ JSON / time / logs
Section 'JSON writer'
$obj = [ordered]@{ s = '中文 "q" <x>'; n = [int64]812345678901; i = 3; d = 662.5; b = $true; f = $false; z = $null; e = @(); h = [ordered]@{}; a = @(1, 'two', $null); o = [ordered]@{ k = 'v' }; p = [pscustomobject]@{ x = 1 } }
$js = ConvertTo-HvJson $obj
$back = ConvertFrom-Json -InputObject $js
Assert-Eq 'json string' '中文 "q" <x>' $back.s
Assert-Eq 'json int64' '812345678901' ([string]$back.n)
Assert-Eq 'json double' '662.5' ([string]$back.d)
Assert-Eq 'json bool' $true $back.b
Assert-Eq 'json null' $null $back.z
Assert-Eq 'json nested' 'v' $back.o.k
Assert-Eq 'json pscustomobject' '1' ([string]$back.p.x)
Assert-True 'json empty array' ($js.Contains('"e": []'))
Assert-True 'json empty object' ($js.Contains('"h": {}'))
Assert-True 'json key order kept' ($js.IndexOf('"s"') -lt $js.IndexOf('"n"') -and $js.IndexOf('"o"') -lt $js.IndexOf('"p"'))
Assert-Eq 'json compact' '{"a":[1,2],"b":"x"}' (ConvertTo-HvJson -Value ([ordered]@{ a = @(1, 2); b = 'x' }) -Indent '')
Assert-Eq 'json single-element array stays array' '[5]' (ConvertTo-HvJson -Value @(5) -Indent '')
Assert-Eq 'json NaN is null' 'null' (ConvertTo-HvJson ([double]::NaN))
Assert-Eq 'json invariant decimal point' '0.25' (ConvertTo-HvJson 0.25)
$utc = [datetime]::new(2026, 9, 26, 3, 30, 0, [System.DateTimeKind]::Utc)
Assert-Eq 'iso time utc' '2026-09-26T03:30:00+00:00' (Format-HvIsoTime $utc)
Assert-True 'iso time local has offset' ((Format-HvIsoTime (Get-Date)) -match '^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d[+-]\d\d:\d\d$')
Assert-Eq 'json datetime' '"2026-09-26T03:30:00+00:00"' (ConvertTo-HvJson $utc)
$jf = Join-Path $OutDir 'json-test/x.json'
Write-HvJsonFile -Path $jf -Value ([ordered]@{ a = 1 })
Write-HvJsonFile -Path $jf -Value ([ordered]@{ a = 2 })
Assert-Eq 'json file replaced atomically' "{`n  `"a`": 2`n}`n" ([System.IO.File]::ReadAllText($jf))
Assert-Eq 'json file no temp left' 1 @(Get-ChildItem -LiteralPath (Split-Path -Parent $jf) -Force).Count
Assert-True 'json file no BOM' ([System.IO.File]::ReadAllBytes($jf)[0] -eq 123)

Section 'logs / env defaults'
Assert-Eq 'cli log path windows' 'D:\HomeVault\logs\homevault\hv-2026-09-26.log' (Get-HvCliLogPath -LogDir 'D:\HomeVault\logs\' -Date $utc)
Assert-Eq 'cli log path posix' '/srv/hv/logs/homevault/hv-2026-09-26.log' (Get-HvCliLogPath -LogDir '/srv/hv/logs' -Date $utc)
Assert-Eq 'cli log path empty' '' (Get-HvCliLogPath -LogDir '' -Date $utc)
Assert-True 'retention 7' (Test-HvRetentionDays '7')
Assert-True 'retention 365' (Test-HvRetentionDays ' 365 ')
Assert-True 'retention 0 invalid' (-not (Test-HvRetentionDays '0'))
Assert-True 'retention 366 invalid' (-not (Test-HvRetentionDays '366'))
Assert-True 'retention text invalid' (-not (Test-HvRetentionDays 'abc'))
Assert-True 'retention empty invalid' (-not (Test-HvRetentionDays ''))
Assert-Eq 'default log dir from data dir' 'D:\HomeVault\logs' (Get-HvDefaultLogDir ([ordered]@{ HV_DATA_DIR = 'D:\HomeVault' }))
Assert-Eq 'default log dir from nc data' 'E:\HV\logs' (Get-HvDefaultLogDir ([ordered]@{ HV_NC_DATA_PATH = 'E:\HV\nextcloud-data' }))
Assert-Eq 'default log dir posix' '/tmp/x/logs' (Get-HvDefaultLogDir ([ordered]@{ HV_DATA_DIR = '/tmp/x/' }))
Assert-Eq 'default log dir none' '' (Get-HvDefaultLogDir ([ordered]@{}))
$dflt = Get-HvEnvDefaults ([ordered]@{ HV_PLATFORM = 'windows'; HV_DATA_DIR = 'D:\HomeVault' })
Assert-Eq 'env defaults for an old .env' 'HV_LOG_DIR=D:\HomeVault\logs;HV_LOG_RETENTION_DAYS=7;HV_PANEL_PORT=9443' ((@($dflt.Keys) | ForEach-Object { $_ + '=' + $dflt[$_] }) -join ';')
$dflt = Get-HvEnvDefaults ([ordered]@{ HV_PLATFORM = 'windows'; HV_DATA_DIR = 'D:\HomeVault'; HV_LOG_DIR = 'F:\logs'; HV_LOG_RETENTION_DAYS = '30'; HV_PANEL_PORT = '19443' })
Assert-Eq 'env defaults keep user values' 0 $dflt.Count
$dflt = Get-HvEnvDefaults ([ordered]@{ HV_PLATFORM = 'windows'; HV_DATA_DIR = 'D:\HomeVault'; HV_LOG_DIR = '/srv/homevault/logs'; HV_LOG_RETENTION_DAYS = '999'; HV_PANEL_PORT = '9443' })
Assert-Eq 'env defaults fix template path + bad retention' 'HV_LOG_DIR=D:\HomeVault\logs;HV_LOG_RETENTION_DAYS=7' ((@($dflt.Keys) | ForEach-Object { $_ + '=' + $dflt[$_] }) -join ';')
Assert-Eq 'log subdirs' 'homevault|backup|nextcloud|caddy|containers|panel' ((Get-HvLogSubdirs) -join '|')
Assert-True 'log dir path windows' (Test-HvLogDirPath 'D:\HomeVault\logs')
Assert-True 'log dir path relative rejected' (-not (Test-HvLogDirPath 'logs'))

Section 'mirror env keys'
$ch = Get-HvMirrorEnvChanges -Env ([ordered]@{ PANEL_IMAGE = 'homevault/panel:1.0.0'; SOCKET_PROXY_IMAGE = 'docker.io/linuxserver/socket-proxy:3.4.5-r0-ls99' }) -Prefixes (Get-HvMirrorPrefixes 'daocloud')
Assert-Eq 'mirror hub env (trailing slash)' 'docker.m.daocloud.io/' $ch['HV_MIRROR_HUB']
Assert-Eq 'mirror ghcr env' 'ghcr.m.daocloud.io/' $ch['HV_MIRROR_GHCR']
Assert-Eq 'mirror panel image untouched' 'homevault/panel:1.0.0' $ch['PANEL_IMAGE']
Assert-Eq 'mirror socket-proxy' 'docker.m.daocloud.io/linuxserver/socket-proxy:3.4.5-r0-ls99' $ch['SOCKET_PROXY_IMAGE']
$ch = Get-HvMirrorEnvChanges -Env ([ordered]@{ NEXTCLOUD_IMAGE = 'docker.m.daocloud.io/library/nextcloud:34-apache' }) -Prefixes (Get-HvMirrorPrefixes 'none')
Assert-Eq 'mirror none clears env' '|' ($ch['HV_MIRROR_HUB'] + '|' + $ch['HV_MIRROR_GHCR'])
$cp = Get-HvMirrorPrefixes -Preset 'custom' -Hub 'hub.example.com/' -Ghcr 'ghcr.example.com'
Assert-Eq 'mirror custom env' 'hub.example.com/|ghcr.example.com/' ($cp.EnvHub + '|' + $cp.EnvGhcr)
Assert-Throws 'mirror custom rejects scheme' { Get-HvMirrorPrefixes -Preset 'custom' -Hub 'https://hub.example.com' -Ghcr 'g.example.com' } '*http*'

# ------------------------------------------------------------------ backup status files (canonical shapes)
Section 'backup status'
$snapJson = '[{"time":"2026-09-25T03:30:01.123456789+08:00","tree":"t","paths":["/src/dumps"],"hostname":"homevault","tags":["homevault"],"id":"aaa","short_id":"aaa1","summary":{"files_new":1,"files_changed":2,"data_added":300,"total_files_processed":10,"total_bytes_processed":4000}},' +
'{"time":"2026-09-26T03:30:05.987654321+08:00","tree":"t","paths":["/src/dumps"],"hostname":"homevault","tags":["homevault"],"id":"bbb","short_id":"bbb1","summary":{"backup_start":"2026-09-26T03:30:05.9+08:00","files_new":12,"files_changed":3,"files_unmodified":5,"data_added":104857600,"total_files_processed":120000,"total_bytes_processed":812345678901}}]'
$st = Get-HvLatestSnapshotStats -Json $snapJson
Assert-Eq 'stats from newest snapshot' 'files_new=12;files_changed=3;data_added=104857600;total_files_processed=120000;total_bytes_processed=812345678901' ((@($st.Keys) | ForEach-Object { $_ + '=' + $st[$_] }) -join ';')
$nb = [datetime]::new(2026, 9, 25, 19, 0, 0, [System.DateTimeKind]::Utc)
Assert-True 'stats kept when snapshot is new' ($null -ne (Get-HvLatestSnapshotStats -Json $snapJson -NotBefore $nb))
Assert-Eq 'stats dropped when snapshot is older than the run' $null (Get-HvLatestSnapshotStats -Json $snapJson -NotBefore $nb.AddDays(1))
Assert-Eq 'stats none without summary' $null (Get-HvLatestSnapshotStats -Json '[{"time":"2026-09-26T03:30:05Z","id":"x"}]')
Assert-Eq 'stats empty list' $null (Get-HvLatestSnapshotStats -Json '[]')
Assert-Eq 'stats garbage' $null (Get-HvLatestSnapshotStats -Json 'Fatal: repository does not exist')
Assert-Eq 'restic time 9 digits' '2026-09-25T19:30:05Z' ((ConvertFrom-HvResticTime '2026-09-26T03:30:05.987654321+08:00').ToString("yyyy-MM-dd'T'HH:mm:ss'Z'"))
Assert-Eq 'restic time invalid' $null (ConvertFrom-HvResticTime 'nope')
$now2 = [datetime]::new(2026, 9, 26, 10, 0, 0)
Assert-Eq 'next daily run tomorrow' '2026-09-27 03:30' ((Get-HvNextDailyRun '03:30' $now2).ToString('yyyy-MM-dd HH:mm'))
Assert-Eq 'next daily run today' '2026-09-26 23:05' ((Get-HvNextDailyRun '23:05' $now2).ToString('yyyy-MM-dd HH:mm'))
Assert-Eq 'next daily run invalid' $null (Get-HvNextDailyRun '24:00' $now2)
Assert-Eq 'repository local' 'E:\HomeVault-Backup\restic' (Get-HvRepositoryDisplay ([ordered]@{ HV_BACKUP_TARGET = 'local'; HV_BACKUP_LOCAL_PATH = 'E:\HomeVault-Backup\restic' }))
Assert-Eq 'repository s3 without credentials' 's3:https://oss.example.com/b/hv' (Get-HvRepositoryDisplay ([ordered]@{ HV_BACKUP_TARGET = 's3'; HV_BACKUP_S3_REPO = 's3:https://AK:SK@oss.example.com/b/hv' }))
Assert-Eq 'backup log rel path' 'backup/backup-20260926-033000.log' (Get-HvBackupLogRelPath ([datetime]::new(2026, 9, 26, 3, 30, 0)))
Assert-Eq 'relative log path windows' 'backup/backup-1.log' (Get-HvPathRelativeTo -Dir 'D:\HomeVault\logs\' -File 'd:\HomeVault\logs\backup\backup-1.log')
Assert-Eq 'relative log path mixed separators' 'backup/x.log' (Get-HvPathRelativeTo -Dir 'D:/HomeVault/logs' -File 'D:\HomeVault\logs\backup\x.log')
Assert-Eq 'relative log path posix' 'backup/x.log' (Get-HvPathRelativeTo -Dir '/srv/hv/logs' -File '/srv/hv/logs/backup/x.log')
Assert-Eq 'relative log path outside' '' (Get-HvPathRelativeTo -Dir 'D:\HomeVault\logs' -File 'D:\HomeVault\logs2\x.log')
Assert-Eq 'relative log path empty dir' '' (Get-HvPathRelativeTo -Dir '' -File 'D:\x.log')
$benv = [ordered]@{ HV_BACKUP_TARGET = 'local'; HV_BACKUP_LOCAL_PATH = 'E:\HomeVault-Backup\restic'; HV_BACKUP_TIME = '03:30' }
$t0 = [datetime]::new(2026, 9, 26, 3, 30, 0, [System.DateTimeKind]::Utc)
$bsOk = New-HvBackupStatus -Env $benv -State 'ok' -Started $t0 -Now $t0.AddSeconds(662) -Finished $t0.AddSeconds(662) -LastSuccess '2026-09-26T03:41:02+00:00' `
    -Message '备份成功' -LogFile 'backup/backup-20260926-033000.log' -NextRun $t0.AddDays(1) -ExitCode 0 -Stats $st
Assert-Eq 'backup status keys' 'updated|state|last_run|last_finished|duration_seconds|last_success|message|log_file|target|repository|schedule|next_run|exit_code|stats' ((@($bsOk.Keys)) -join '|')
Assert-Eq 'backup status duration' '662' ([string]$bsOk['duration_seconds'])
Assert-Eq 'backup status times' '2026-09-26T03:30:00+00:00|2026-09-26T03:41:02+00:00|2026-09-27T03:30:00+00:00' ($bsOk['last_run'] + '|' + $bsOk['last_finished'] + '|' + $bsOk['next_run'])
$bsRun = New-HvBackupStatus -Env $benv -State 'running' -Started $t0 -Now $t0
Assert-Eq 'running status keys' 'updated|state|last_run|last_finished|duration_seconds|last_success|message|log_file|target|repository|schedule' ((@($bsRun.Keys)) -join '|')
Assert-True 'running: null finished / success' ($null -eq $bsRun['last_finished'] -and $null -eq $bsRun['last_success'])
$bsJson = ConvertTo-HvJson $bsOk
$bsBack = ConvertFrom-Json -InputObject $bsJson
Assert-Eq 'backup status json stats' '12' ([string]$bsBack.stats.files_new)
Assert-Eq 'backup status json exit code' '0' ([string]$bsBack.exit_code)
Write-HvTextFile -Path (Join-Path $OutDir 'state/backup-status.json') -Content ($bsJson + "`n")
Write-HvTextFile -Path (Join-Path $OutDir 'state/snapshots.json') -Content $snapJson
Write-HvTextFile -Path (Join-Path $OutDir 'state/backup-status-running.json') -Content ((ConvertTo-HvJson $bsRun) + "`n")
Write-HvTextFile -Path (Join-Path $OutDir 'state/backup-status-failed.json') -Content ((ConvertTo-HvJson (New-HvBackupStatus -Env $benv -State 'failed' -Started $t0 -Now $t0.AddMinutes(1) -Finished $t0.AddMinutes(1) -Message '备份目录不可用' -ExitCode 1)) + "`n")
# field names must be the json tags of the Go types (canonical contract)
$typesGo = Join-Path $Root 'panel/internal/hoststate/types.go'
if (Test-Path -LiteralPath $typesGo) {
    $goText = [System.IO.File]::ReadAllText($typesGo)
    function Get-GoJsonTags { param([string]$Text, [string]$Struct)
        $m = [regex]::Match($Text, '(?s)type ' + $Struct + ' struct \{(.*?)\n\}')
        return @([regex]::Matches($m.Groups[1].Value, 'json:"([a-z_]+)') | ForEach-Object { $_.Groups[1].Value })
    }
    $bTags = @(Get-GoJsonTags $goText 'BackupStatus')
    Assert-True 'Go BackupStatus tags found' ($bTags.Count -ge 10)
    foreach ($k in $bsOk.Keys) { Assert-True ('backup-status key "' + $k + '" is a Go json tag') ($bTags -contains $k) }
    $sTags = @(Get-GoJsonTags $goText 'BackupStats')
    foreach ($k in $st.Keys) { Assert-True ('stats key "' + $k + '" is a Go json tag') ($sTags -contains $k) }
} else { Write-Host '  (panel/internal/hoststate/types.go not found - contract tag check skipped)' }

Section 'wg show dump (vpn list)'
$dumpText = "SRVPRIV=`tSRVPUB=`t43210`toff`n" +
"PUB1=`tPSK1=`t203.0.113.9:40000`t10.99.77.2/32`t1790388000`t1048576`t2097152`t0`n" +
"PUB2=`t(none)`t(none)`t10.99.77.3/32`t0`t0`t0`toff"
$dump = ConvertFrom-HvWgShowDumpText $dumpText
Assert-Eq 'dump peers' 2 $dump.Count
Assert-Eq 'dump handshake' '1790388000' ([string]$dump['PUB1='].Handshake)
Assert-Eq 'dump rx/tx' '1048576/2097152' ([string]$dump['PUB1='].Rx + '/' + [string]$dump['PUB1='].Tx)
Assert-Eq 'dump no endpoint' '' $dump['PUB2='].Endpoint
Assert-True 'dump interface line skipped' (-not $dump.ContainsKey('SRVPRIV='))
Assert-Eq 'dump empty' 0 (ConvertFrom-HvWgShowDumpText '').Count

Write-Host ''
Write-Host ('unit tests: ' + $script:Pass + ' passed, ' + $script:Fail + ' failed')
if ($script:Fail -gt 0) { exit 1 }
exit 0
