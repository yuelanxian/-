# HomeVault Windows CLI - install (idempotent; re-running never regenerates secrets).

function Get-HvRandomPort {
    # CSPRNG port in [20000, 60000].
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    try {
        $b = New-Object byte[] 4
        while ($true) {
            $rng.GetBytes($b)
            $n = [BitConverter]::ToUInt32($b, 0)
            if ($n -lt 4294967295 - (4294967295 % 40001)) { return (20000 + ($n % 40001)) }
        }
    } finally { $rng.Dispose() }
}

function Test-HvPortNumber {
    param([AllowEmptyString()][string]$Text)
    $n = 0
    if (-not [int]::TryParse($Text, [ref]$n)) { return $false }
    return ($n -ge 1 -and $n -le 65535)
}

function Test-HvLogDirPath {
    # Pure: absolute Windows path (D:\HomeVault\logs) or, for tests on Linux, an absolute POSIX path.
    param([AllowEmptyString()][string]$Path)
    return (($Path -match '^[A-Za-z]:[\\/]') -or $Path.StartsWith('/'))
}

function Test-HvDriveRoot {
    # Pure: a whole drive ("D:", "D:\") or the POSIX root - never usable as a HomeVault folder: install sets a
    # private ACL on these folders (a drive root would change the permissions of the entire drive) and the log
    # retention deletes old *.log / *.txt files below the log folder.
    param([AllowEmptyString()][string]$Path)
    $t = ([string]$Path).Trim()
    return ($t -eq '' -or $t -match '^[A-Za-z]:[\\/]?$' -or $t -match '^[\\/]+$')
}

function Invoke-HvOptionalStep {
    # Run a function provided by another windows\lib module if present (older/partial checkouts skip it).
    param([string]$Function, [string]$What)
    if (-not (Get-Command -Name $Function -CommandType Function -ErrorAction SilentlyContinue)) {
        Write-HvWarn ('跳过' + $What + '（缺少 ' + $Function + '）。')
        return
    }
    try { [void](& $Function) } catch { Write-HvWarn ($What + '未完成：' + (Get-HvErrorMessage $_)) }
}

function Get-HvInstallValue {
    # First non-empty of: command-line option, current .env value, default.
    param([hashtable]$Parsed, [string]$Opt, [System.Collections.IDictionary]$Cur, [string]$Key, [string]$Default = '')
    if ($Opt) {
        $v = Get-HvOpt $Parsed $Opt $null
        if ($null -ne $v -and [string]$v -ne '') { return [string]$v }
    }
    if ($Key -and $Cur.Contains($Key) -and [string]$Cur[$Key] -ne '') { return [string]$Cur[$Key] }
    return $Default
}

function Select-HvDataLocation {
    param([hashtable]$Parsed, [System.Collections.IDictionary]$Cur, [object[]]$Disks)
    $curData = Get-HvEnvDictValue $Cur 'HV_NC_DATA_PATH'
    $base = ''
    $dataDir = Get-HvOpt $Parsed 'data-dir' ''
    $drive = Get-HvOpt $Parsed 'data-drive' ''
    if ($dataDir) {
        $base = $dataDir.TrimEnd('\').TrimEnd('/')
    } elseif ($drive) {
        $d = Find-HvDisk $Disks $drive
        if ((Test-HvWindows) -and $null -eq $d) { Stop-Hv ('找不到盘符 ' + $drive + ':') 2 }
        $base = $drive.Trim().TrimEnd('\').TrimEnd(':').ToUpperInvariant() + ':\HomeVault'
    } elseif ($curData) {
        $leaf = Split-Path -Leaf $curData
        if ($leaf -eq 'nextcloud-data') { $base = Split-Path -Parent $curData } else { return @{ Base = (Split-Path -Parent $curData); NcData = $curData } }
    } else {
        if (-not (Test-HvWindows)) { Stop-Hv '请用 --data-dir 指定数据目录。' 2 }
        $def = Get-HvDefaultDataDisk $Disks
        $defLetter = 'D'
        if ($def) { $defLetter = $def.Letter }
        Write-HvInfo '主数据盘用于存放 Nextcloud 的全部文件（手机照片/视频等），建议选择容量最大的非系统盘。'
        $letter = Read-HvValue -Prompt '请选择主数据盘（输入盘符）' -Default $defLetter -Validate { param($v) $null -ne (Find-HvDisk $Disks $v) } -ErrorText '请输入上表中存在的盘符，例如 D'
        $base = $letter.Trim().TrimEnd(':').ToUpperInvariant() + ':\HomeVault'
    }
    if ($dataDir -and (Test-HvDriveRoot $base)) { Stop-Hv ('数据目录不能是整个盘的根目录（' + $dataDir + '），请指定一个文件夹，例如 D:\HomeVault') 2 }
    $sep = '\'
    if (-not (Test-HvWindows) -and $base.StartsWith('/')) { $sep = '/' }
    $nc = $base + $sep + 'nextcloud-data'
    if ($curData -and $curData -ne $nc) {
        Write-HvWarn ('主数据目录将从 ' + $curData + ' 改为 ' + $nc + '：HomeVault 不会自动迁移已有文件！')
        if (-not (Read-HvYesNo '确认更改主数据目录？' $false)) { Stop-Hv '已取消。' }
    }
    if (Test-HvWindows) {
        $disk = Find-HvDisk $Disks (Get-HvDriveLetterFromPath $base)
        $warns = @(Get-HvDiskWarnings -Disk $disk -Role 'primary')
        foreach ($w in $warns) { Write-HvWarn $w }
        if ($warns.Count -gt 0 -and -not $curData) {
            if (-not (Read-HvYesNo ('仍然使用 ' + $base + ' 作为主数据目录？') $false)) { Stop-Hv '已取消：请用 --data-drive 选择其他盘。' }
        }
    }
    return @{ Base = $base; NcData = $nc }
}

function Select-HvBackupLocation {
    param([hashtable]$Parsed, [System.Collections.IDictionary]$Cur, [object[]]$Disks, [string]$DataBase)
    $res = [ordered]@{}
    $target = Get-HvInstallValue $Parsed 'backup-target' $Cur 'HV_BACKUP_TARGET' ''
    $path = Get-HvOpt $Parsed 'backup-path' ''
    $drive = Get-HvOpt $Parsed 'backup-drive' ''
    if ($path -or $drive) { $target = 'local' }
    if (-not $target) {
        $dataDisk0 = Find-HvDisk $Disks (Get-HvDriveLetterFromPath $DataBase)
        $defTarget = 'none'
        foreach ($d in @($Disks)) { if ($null -ne $dataDisk0 -and -not (Test-HvSamePhysicalDisk $d $dataDisk0)) { $defTarget = 'local' } }
        Write-HvInfo '备份：restic 加密备份到“另一块硬盘”（例如 USB 移动硬盘，local）或 S3 兼容的对象存储（阿里云 OSS / 腾讯云 COS，s3）。'
        $target = Read-HvValue -Prompt '备份目标（local / s3 / none）' -Default $defTarget -Validate { param($v) @('local', 's3', 'none') -contains $v }
    }
    if (@('local', 's3', 'none') -notcontains $target) { Stop-Hv ('--backup-target 只能是 local / s3 / none：' + $target) 2 }
    $res['HV_BACKUP_TARGET'] = $target
    if ($target -eq 'local') {
        if (-not $path -and $drive) { $path = $drive.Trim().TrimEnd('\').TrimEnd(':').ToUpperInvariant() + ':\HomeVault-Backup\restic' }
        $fromEnv = $false
        if (-not $path) { $path = Get-HvEnvDictValue $Cur 'HV_BACKUP_LOCAL_PATH'; $fromEnv = [bool]$path }
        if (-not $path) {
            if (-not (Test-HvWindows)) { Stop-Hv '请用 --backup-path 指定备份目录。' 2 }
            $dataDisk = Find-HvDisk $Disks (Get-HvDriveLetterFromPath $DataBase)
            $best = $null
            foreach ($d in @($Disks)) { if (-not (Test-HvSamePhysicalDisk $d $dataDisk) -and (-not $best -or $d.FreeBytes -gt $best.FreeBytes)) { $best = $d } }
            $def = ''
            if ($best) { $def = $best.Letter }
            $letter = Read-HvValue -Prompt '备份放在哪个盘（输入盘符，最好是另一块物理硬盘）' -Default $def -Validate { param($v) $null -ne (Find-HvDisk $Disks $v) } -ErrorText '请输入上表中存在的盘符'
            $path = $letter.Trim().TrimEnd(':').ToUpperInvariant() + ':\HomeVault-Backup\restic'
        }
        $path = $path.Trim()
        if (Test-HvDriveRoot $path) {
            if (-not $fromEnv) { Stop-Hv ('备份目录不能是整个盘的根目录（' + $path + '），请指定一个文件夹，例如 E:\HomeVault-Backup\restic') 2 }
            Write-HvWarn ('备份目录是整个盘的根目录（' + $path + '）：建议改为一个专用文件夹（--backup-path）。')
        } else { $path = $path.TrimEnd('\', '/') }
        if (Test-HvWindows) {
            if (-not (Test-HvWindowsAbsPath $path)) { Stop-Hv ('备份路径必须是完整路径：' + $path) 2 }
            $bd = Find-HvDisk $Disks (Get-HvDriveLetterFromPath $path)
            $dd = Find-HvDisk $Disks (Get-HvDriveLetterFromPath $DataBase)
            $rwDisks = @()
            foreach ($r in @(Get-HvStorageRows)) { if (-not $r.ReadOnly) { $rwDisks += (Find-HvDisk $Disks (Get-HvDriveLetterFromPath $r.Path)) } }
            $warns = @(Get-HvBackupDiskWarnings -BackupDisk $bd -PrimaryDisk $dd -RwStorageDisks $rwDisks) + @(Get-HvDiskWarnings -Disk $bd -Role 'backup')
            foreach ($w in $warns) { Write-HvWarn $w }
            if ($warns.Count -gt 0 -and -not (Read-HvYesNo '仍然使用这个备份位置？' $false)) { Stop-Hv '已取消：请用 --backup-drive 选择其他硬盘。' }
        }
        $res['HV_BACKUP_LOCAL_PATH'] = $path
    } elseif ($target -eq 's3') {
        $repo = Get-HvInstallValue $Parsed 's3-repo' $Cur 'HV_BACKUP_S3_REPO' ''
        if (-not $repo) { $repo = Read-HvValue -Prompt 'S3 仓库（例如 s3:https://oss-cn-hongkong.aliyuncs.com/桶名/homevault）' -Validate { param($v) $v -like 's3:*' } }
        $opts = Get-HvInstallValue $Parsed 's3-options' $Cur 'HV_BACKUP_S3_OPTIONS' ''
        if (-not $opts -and (Test-HvInteractive)) { $opts = Read-HvValue -Prompt 'restic S3 选项' -Default '-o s3.bucket-lookup=dns' }
        $res['HV_BACKUP_S3_REPO'] = $repo
        $res['HV_BACKUP_S3_OPTIONS'] = $opts
        $credFile = Get-HvSecretPath 'backup.env'
        if (-not [System.IO.File]::Exists($credFile) -or (Get-HvOpt $Parsed 's3-repo' '')) {
            $ak = Read-HvSecretValue -Prompt 'S3 AccessKey ID' -EnvName 'AWS_ACCESS_KEY_ID'
            $sk = Read-HvSecretValue -Prompt 'S3 AccessKey Secret' -EnvName 'AWS_SECRET_ACCESS_KEY'
            [void](Initialize-HvSecretsDir)
            Write-HvTextFile -Path $credFile -Content (ConvertTo-HvEnvFileText ([ordered]@{ AWS_ACCESS_KEY_ID = $ak; AWS_SECRET_ACCESS_KEY = $sk }))
        }
    }
    return $res
}

function Read-HvInstallStorages {
    # --storage "名称|路径|rw|no|用户" (repeatable) and/or interactive additions to storage.conf.
    param([hashtable]$Parsed, [object[]]$Disks)
    $text = Read-HvStorageConfText
    if (-not $text) { $text = Get-HvStorageConfHeader }
    $existing = @()
    try { $existing = @(ConvertFrom-HvStorageConf $text) } catch { Stop-Hv $_.Exception.Message }
    foreach ($line in @(Get-HvOpt $Parsed 'storage' @())) {
        if (-not $line) { continue }
        $name = (($line -split '\|')[0]).Trim()
        if (@($existing | Where-Object { $_.Name -eq $name }).Count -gt 0) { Write-HvInfo ('存储已存在，跳过：' + $name); continue }
        try { $text = Add-HvStorageConfLine -Text $text -Line $line } catch { Stop-Hv $_.Exception.Message 2 }
        $spath = (($line -split '\|')[1]).Trim()
        if ((Test-HvWindows) -and -not [System.IO.Directory]::Exists($spath)) { Write-HvWarn ('存储目录不存在：' + $spath + '（启动前请创建或连接对应硬盘）') }
        Write-HvOk ('添加存储：' + $line)
    }
    Write-HvTextFile -Path (Get-HvStorageConfPath) -Content $text
    if ((Test-HvInteractive) -and (Test-HvWindows)) {
        $ask = '是否添加额外的归档存储（其他硬盘上已有的资料文件夹，会显示为 Nextcloud 中的文件夹）？'
        if (@(ConvertFrom-HvStorageConf $text).Count -gt 0) { $ask = '是否再添加额外的归档存储？' }
        while (Read-HvYesNo $ask $false) {
            $path = Read-HvValue -Prompt '文件夹路径（例如 E:\Photos）' -Validate { param($v) Test-HvWindowsAbsPath $v } -ErrorText '请输入完整路径，例如 E:\Photos'
            $name = Read-HvValue -Prompt '在 Nextcloud 中显示的名称' -Default (Split-Path -Leaf $path.TrimEnd('\')) -Validate { param($v) Test-HvStorageName $v }
            $mode = 'rw'; if (-not (Read-HvYesNo '允许通过 Nextcloud 修改/删除其中的文件？（n = 只读）' $true)) { $mode = 'ro' }
            $bk = 'no'; if (Read-HvYesNo '是否包含在 restic 备份中？' $false) { $bk = 'yes' }
            $users = Read-HvValue -Prompt '可见用户（留空=所有用户；逗号分隔；@开头为群组）' -Default ''
            Add-HvStorage -Name $name -Path $path -Mode $mode -Backup $bk -Users $users
            $ask = '是否再添加一个？'
        }
    }
}

function Show-HvInstallSummary {
    param([string[]]$Created, [string]$CaPath)
    $url = Get-HvCanonicalUrl
    $port = Get-HvEnvValue 'WG_PORT'
    $lan = Get-HvEnvValue 'HV_LAN_IP'
    Write-Host ''
    Write-Host '==================== HomeVault 安装完成 ====================' -ForegroundColor Green
    Write-Host ('  访问地址（家里和外面都用这一个）：' + $url)
    Write-Host ('  管理面板（手机/浏览器查看状态、存储、备份、日志）：' + (Get-HvPanelUrl) + '（用 Nextcloud 管理员账号登录）')
    Write-Host ('  管理员用户名：' + (Get-HvEnvValue 'HV_ADMIN_USER' 'hvadmin'))
    if (@($Created) -contains 'nextcloud_admin_password') {
        Write-Host ('  管理员初始密码（只显示这一次，请立即保存）：' + (Read-HvSecret 'nextcloud_admin_password')) -ForegroundColor Yellow
    } else {
        Write-Host '  管理员密码：见 secrets\nextcloud_admin_password（如已在网页修改则以新密码为准）'
    }
    $bt = Get-HvEnvValue 'HV_BACKUP_TARGET'
    if (($bt -eq 'local' -or $bt -eq 's3') -and @($Created) -contains 'restic_password') {
        Write-Host ('  备份密码（restic，只显示这一次，请抄写后离线保存；丢失 = 备份无法恢复）：' + (Read-HvSecret 'restic_password')) -ForegroundColor Yellow
    }
    if ($CaPath) {
        $fp = Get-HvCertFingerprint $CaPath
        Write-Host ('  根证书：' + $CaPath)
        Write-Host ('  根证书 SHA-256 指纹：' + $fp.Fingerprint)
    }
    Write-Host ('  日志目录：' + (Get-HvEnvLogDir) + '（保留 ' + (Get-HvEnvValue 'HV_LOG_RETENTION_DAYS' '7') + ' 天）')
    if (Test-HvTrue (Get-HvEnvValue 'HV_VPN_ENABLED' 'true')) {
        Write-Host ''
        Write-Host ('  路由器设置：只把 UDP ' + $port + ' 端口转发到 ' + $lan + '（不要开 DMZ，不要转发 443）。') -ForegroundColor Cyan
        Write-Host ('  VPN 地址（Endpoint）：' + (Get-HvEnvValue 'WG_HOST') + ':' + $port)
    }
    Write-Host ''
    Write-Host '  下一步（手机自动备份）：'
    $n = 1
    if ($CaPath) { Write-Host ('   ' + $n + '. 把根证书 homevault-root-ca.crt 传到手机并安装（设置 → 搜索“证书” → 安装 CA 证书）。'); $n++ }
    if (Test-HvTrue (Get-HvEnvValue 'HV_VPN_ENABLED' 'true')) {
        Write-Host ('   ' + $n + '. 管理员 PowerShell 运行：.\windows\hv.ps1 vpn add phone1 → 用 WG Tunnel（推荐）或 WireGuard App 扫码。'); $n++
    }
    Write-Host ('   ' + $n + '. 安装 Nextcloud 安卓 App（F-Droid 或 GitHub），服务器填 ' + $url + '，用“应用密码”登录。'); $n++
    Write-Host ('   ' + $n + '. App 设置 → 自动上传：打开相机文件夹，上传到 /手机备份/<设备名>；可选“仅在未计费 Wi-Fi 上传”。'); $n++
    Write-Host ('   ' + $n + '. 手机设置里把 Nextcloud 和 VPN App 的电池优化设为“无限制”，并允许自启动。'); $n++
    Write-Host ('   ' + $n + '. 为家人创建账号：.\windows\hv.ps1 user add 名字；检查状态：.\windows\hv.ps1 doctor'); $n++
    Write-Host ('   ' + $n + '. 日常管理：双击桌面“HomeVault 管理”（或 .\windows\hv.ps1 menu）；手机管理可安装 HomeVault 安卓 App（管理面板“设置”页扫码下载）。')
    Write-Host '  详细说明：docs\05-安卓手机备份.md、docs\03-Windows部署.md'
    Write-Host '============================================================' -ForegroundColor Green
}

function Invoke-HvCmdInstall {
    param([object[]]$Arguments = @())
    $p = Read-HvCommandArgs -Arguments $Arguments `
        -Switches @('no-vpn', 'config-only', 'skip-autostart', 'skip-backup-init') `
        -Options @('host', 'lan-ip', 'lan-cidr', 'data-drive', 'data-dir', 'backup-target', 'backup-drive', 'backup-path', 's3-repo', 's3-options',
        'wg-host', 'wg-port', 'vpn-cidr', 'vpn-dns', 'tls-mode', 'dns-provider', 'acme-email', 'mirror', 'mirror-hub', 'mirror-ghcr',
        'https-port', 'http-port', 'admin-port', 'panel-port', 'admin-user', 'extra-hosts', 'bind-ip', 'timezone', 'log-dir', 'log-retention') `
        -MultiOptions @('storage')
    $configOnly = Test-HvOpt $p 'config-only'
    if (-not $configOnly) { Assert-HvAdmin 'install' }
    $root = Get-HvRoot
    Write-HvStep 'HomeVault 安装 / 重新配置（Windows）'
    if (Test-HvWindows) {
        Get-ChildItem -LiteralPath (Join-HvPath $root 'windows') -Recurse -File -ErrorAction SilentlyContinue | Unblock-File -ErrorAction SilentlyContinue
        $build = [System.Environment]::OSVersion.Version.Build
        if ($build -lt 22000) { Write-HvWarn 'Windows 10 已停止主流支持（消费者 ESU 到 2026-10-13 结束），Docker Desktop 也只支持仍在服务期内的 Windows，建议升级到 Windows 11。' }
    }
    if (-not $configOnly) {
        $di = Assert-HvDocker -OfferInstall
        if ($di.DesktopVersion -and (Compare-HvVersion $di.DesktopVersion '4.92.0') -lt 0) {
            Write-HvWarn ('Docker Desktop ' + $di.DesktopVersion + ' 低于 4.92：把磁盘镜像迁移到其他盘的功能有已知问题，建议先升级。')
        }
        Write-HvOk ('Docker ' + $di.ServerVersion + '，Compose ' + $di.ComposeVersion)
    }

    # ---- current values (existing .env, else .env.example defaults)
    $envPath = Get-HvEnvPath
    $isNew = -not [System.IO.File]::Exists($envPath)
    if ($isNew) {
        $ex = Get-HvPath '.env.example'
        if (-not [System.IO.File]::Exists($ex)) { Stop-Hv ('缺少 ' + $ex + '，仓库不完整。') }
        $cur = ConvertFrom-HvEnvText (Read-HvTextFile $ex)
        # the template's host-specific sample values are not choices of this machine
        foreach ($k in @('HV_HOST', 'HV_LAN_IP', 'HV_LAN_CIDR', 'HV_BIND_IP', 'HV_DATA_DIR', 'HV_NC_DATA_PATH', 'HV_DUMP_DIR', 'HV_LOG_DIR', 'HV_BACKUP_TARGET', 'HV_BACKUP_LOCAL_PATH', 'WG_HOST', 'WG_PORT')) {
            if ($cur.Contains($k)) { $cur[$k] = '' }
        }
        Write-HvInfo '首次安装：从 .env.example 生成 .env'
    } else {
        $cur = (Read-HvEnvFile $envPath).Values
        Write-HvInfo '检测到已有 .env：保留现有设置和密钥（升级安全），只更新你指定的项。'
    }
    $set = [ordered]@{}
    $set['HV_PLATFORM'] = 'windows'
    if (-not (Get-HvEnvDictValue $cur 'COMPOSE_PROJECT_NAME')) { $set['COMPOSE_PROJECT_NAME'] = 'homevault' }
    $bind = Get-HvOpt $p 'bind-ip' ''
    if (-not $bind) {
        $bind = '0.0.0.0'
        if (-not $isNew -and (Get-HvEnvDictValue $cur 'HV_PLATFORM') -eq 'windows') { $bind = Get-HvEnvDictValue $cur 'HV_BIND_IP' '0.0.0.0' }
    }
    $set['HV_BIND_IP'] = $bind
    $seenPorts = @{}
    foreach ($pp in @(@('https-port', 'HV_HTTPS_PORT', '443'), @('http-port', 'HV_HTTP_PORT', '80'), @('admin-port', 'HV_ADMIN_PORT', '8443'), @('panel-port', 'HV_PANEL_PORT', '9443'))) {
        $v = Get-HvInstallValue $p $pp[0] $cur $pp[1] $pp[2]
        if (-not (Test-HvPortNumber $v)) { Stop-Hv ('端口无效：--' + $pp[0] + ' ' + $v) 2 }
        $v = [string][int]$v
        if ($seenPorts.ContainsKey($v)) { Stop-Hv ('端口冲突：--' + $pp[0] + ' 与 --' + $seenPorts[$v] + ' 都是 ' + $v) 2 }
        $seenPorts[$v] = $pp[0]
        $set[$pp[1]] = $v
    }
    if (-not $configOnly) {
        foreach ($k in @('HV_HTTPS_PORT', 'HV_HTTP_PORT', 'HV_ADMIN_PORT', 'HV_PANEL_PORT')) {
            $owners = @(Test-HvTcpPortListening ([int]$set[$k]))
            $foreign = @($owners | Where-Object { $_ -notmatch '^(com\.docker\.backend|wslrelay|vpnkit|com\.docker\.proxy)' })
            if ($foreign.Count -gt 0) { Stop-Hv ('TCP 端口 ' + $set[$k] + ' 已被 ' + ($foreign -join ', ') + ' 占用：请关闭该程序或使用 --https-port / --http-port 指定其他端口。') }
        }
    }

    # ---- LAN
    Write-HvStep '局域网'
    $cands = @(Get-HvLanCandidates)
    $lanIp = Get-HvOpt $p 'lan-ip' ''
    if (-not $lanIp) {
        $lanIp = Get-HvEnvDictValue $cur 'HV_LAN_IP'
        if ($lanIp -and (Test-HvWindows) -and (@(Get-HvLocalIPv4s) -notcontains $lanIp)) { Write-HvWarn ('原局域网 IP ' + $lanIp + ' 已不在本机上，将重新检测。'); $lanIp = '' }
    }
    if (-not $lanIp) {
        $def = ''
        if ($cands.Count -gt 0) { $def = $cands[0].Ip }
        if ($cands.Count -gt 1) { foreach ($c in $cands) { Write-HvInfo ($c.Alias + '：' + $c.Ip + '/' + $c.Prefix + '（网关 ' + $c.Gateway + '）') } }
        $lanIp = Read-HvValue -Prompt '本机局域网 IPv4 地址' -Default $def -Validate { param($v) Test-HvIPv4 $v } -ErrorText '请输入 IPv4 地址，例如 192.168.1.10'
    }
    if (-not (Test-HvIPv4 $lanIp)) { Stop-Hv ('局域网 IP 无效：' + $lanIp) 2 }
    $lanCidr = Get-HvOpt $p 'lan-cidr' ''
    if (-not $lanCidr) { foreach ($c in $cands) { if ($c.Ip -eq $lanIp) { $lanCidr = $c.Cidr } } }
    if (-not $lanCidr) { $lanCidr = Get-HvEnvDictValue $cur 'HV_LAN_CIDR' }
    if (-not $lanCidr -or -not (Test-HvIpInCidr $lanIp $lanCidr)) { $lanCidr = Get-HvNetworkCidr $lanIp 24 }
    $lanCidr = (Get-HvCidrInfo $lanCidr).Cidr
    $set['HV_LAN_IP'] = $lanIp
    $set['HV_LAN_CIDR'] = $lanCidr
    Write-HvOk ('局域网：' + $lanIp + '（' + $lanCidr + '）')
    Write-HvInfo '请在路由器里为本机设置“静态 DHCP / IP 与 MAC 绑定”，保证这个 IP 以后不变。'

    # ---- host & TLS
    Write-HvStep '访问地址与证书'
    $hostName = Get-HvOpt $p 'host' ''
    if (-not $hostName) {
        $hostName = Get-HvEnvDictValue $cur 'HV_HOST'
        if (-not $hostName -or ($isNew -and (Test-HvIPv4 $hostName))) { $hostName = $lanIp }
        if ($isNew -or (Test-HvInteractive)) {
            Write-HvInfo '手机和电脑都使用同一个地址：局域网 IP（简单，需要在手机上安装根证书）或 一个解析到局域网 IP 的域名（推荐，证书自动受信任，需要 DNS API）。'
            $hostName = Read-HvValue -Prompt '客户端访问地址（IP 或域名）' -Default $hostName -Validate { param($v) Test-HvHostName $v } -ErrorText '请输入 IPv4 地址或域名'
        }
    }
    if (-not (Test-HvHostName $hostName)) { Stop-Hv ('访问地址无效：' + $hostName) 2 }
    $tls = Get-HvOpt $p 'tls-mode' ''
    if (-not $tls) {
        $tls = Get-HvEnvDictValue $cur 'HV_TLS_MODE' 'internal'
        if (Test-HvDomainName $hostName) {
            if (Get-HvOpt $p 'dns-provider' '') { $tls = 'acme-dns' }
            elseif (Test-HvInteractive) {
                $defMode = 'acme-dns'; if ($tls -eq 'internal' -and -not $isNew) { $defMode = 'internal' }
                $tls = Read-HvValue -Prompt '证书模式：acme-dns（Let''s Encrypt 真证书，需 DNS API 密钥）/ internal（本地 CA，需在每台设备安装根证书）' -Default $defMode -Validate { param($v) @('acme-dns', 'internal') -contains $v }
            }
        } else { $tls = 'internal' }
    }
    if (@('internal', 'acme-dns') -notcontains $tls) { Stop-Hv '--tls-mode 只能是 internal 或 acme-dns' 2 }
    if ($tls -eq 'acme-dns' -and -not (Test-HvDomainName $hostName)) { Stop-Hv 'acme-dns 模式需要使用域名作为访问地址（--host）。' 2 }
    $set['HV_HOST'] = $hostName
    $set['HV_TLS_MODE'] = $tls
    if ($tls -eq 'acme-dns') {
        $prov = Get-HvInstallValue $p 'dns-provider' $cur 'HV_DNS_PROVIDER' ''
        if (-not $prov) { $prov = Read-HvValue -Prompt 'DNS 服务商（alidns / tencentcloud / cloudflare）' -Default 'alidns' -Validate { param($v) @('alidns', 'tencentcloud', 'cloudflare') -contains $v } }
        if (@('alidns', 'tencentcloud', 'cloudflare') -notcontains $prov) { Stop-Hv '--dns-provider 只能是 alidns / tencentcloud / cloudflare' 2 }
        $set['HV_DNS_PROVIDER'] = $prov
        $email = Get-HvInstallValue $p 'acme-email' $cur 'HV_ACME_EMAIL' ''
        if (-not $email -and (Test-HvInteractive)) { $email = Read-HvValue -Prompt '证书通知邮箱（可留空）' -Default '' }
        $set['HV_ACME_EMAIL'] = $email
        $credFile = Get-HvSecretPath 'caddy-dns.env'
        $needCreds = -not [System.IO.File]::Exists($credFile) -or ((Get-HvEnvDictValue $cur 'HV_DNS_PROVIDER') -ne $prov)
        if ($needCreds) {
            $vals = [ordered]@{}
            if ($prov -eq 'alidns') {
                $vals['ALIYUN_ACCESS_KEY_ID'] = Read-HvSecretValue -Prompt '阿里云 AccessKey ID（建议 RAM 子账号，仅授权云解析）' -EnvName 'ALIYUN_ACCESS_KEY_ID'
                $vals['ALIYUN_ACCESS_KEY_SECRET'] = Read-HvSecretValue -Prompt '阿里云 AccessKey Secret' -EnvName 'ALIYUN_ACCESS_KEY_SECRET'
            } elseif ($prov -eq 'tencentcloud') {
                $vals['TENCENTCLOUD_SECRET_ID'] = Read-HvSecretValue -Prompt '腾讯云 SecretId（建议子账号，仅授权 DNSPod）' -EnvName 'TENCENTCLOUD_SECRET_ID'
                $vals['TENCENTCLOUD_SECRET_KEY'] = Read-HvSecretValue -Prompt '腾讯云 SecretKey' -EnvName 'TENCENTCLOUD_SECRET_KEY'
            } else {
                $vals['CF_API_TOKEN'] = Read-HvSecretValue -Prompt 'Cloudflare API Token（仅该域名 Zone:DNS:Edit）' -EnvName 'CF_API_TOKEN'
            }
            [void](Initialize-HvSecretsDir)
            Write-HvTextFile -Path $credFile -Content (ConvertTo-HvEnvFileText $vals)
        }
        $res = @(Resolve-HvHostIPv4 $hostName)
        if ($res -notcontains $lanIp) {
            Write-HvWarn ('域名 ' + $hostName + ' 当前解析为 ' + (($res -join ', ')) + '：请在 DNS 服务商处添加 A 记录 ' + $hostName + ' → ' + $lanIp + '（局域网 IP）。部分路由器的“DNS 重绑定保护”会拦截这种记录，需要放行。')
        }
    }
    $extra = Get-HvInstallValue $p 'extra-hosts' $cur 'HV_EXTRA_HOSTS' ''
    $set['HV_EXTRA_HOSTS'] = $extra
    $adminUser = Get-HvInstallValue $p 'admin-user' $cur 'HV_ADMIN_USER' 'hvadmin'
    if (-not $isNew -and (Get-HvEnvDictValue $cur 'HV_ADMIN_USER') -and $adminUser -ne (Get-HvEnvDictValue $cur 'HV_ADMIN_USER')) { Write-HvWarn 'Nextcloud 已安装后修改 HV_ADMIN_USER 不会改名已有管理员。' }
    $set['HV_ADMIN_USER'] = $adminUser
    $tz = Get-HvInstallValue $p 'timezone' $cur 'HV_TZ' 'Asia/Shanghai'
    $set['HV_TZ'] = $tz

    # ---- disks
    Write-HvStep '硬盘与数据目录'
    $disks = @(Get-HvDiskInventory)
    if ($disks.Count -gt 0) { foreach ($l in (Format-HvDiskTable $disks)) { Write-Host ('  ' + $l) } }
    $loc = Select-HvDataLocation -Parsed $p -Cur $cur -Disks $disks
    $sep = '\'
    if (-not (Test-HvWindows) -and $loc.Base.StartsWith('/')) { $sep = '/' }
    $set['HV_DATA_DIR'] = $loc.Base
    $set['HV_NC_DATA_PATH'] = $loc.NcData
    $dump = $loc.Base + $sep + 'dumps'
    if (-not $isNew -and (Get-HvEnvDictValue $cur 'HV_PLATFORM') -eq 'windows' -and (Get-HvEnvDictValue $cur 'HV_DATA_DIR') -eq $loc.Base -and (Get-HvEnvDictValue $cur 'HV_DUMP_DIR')) {
        $dump = Get-HvEnvDictValue $cur 'HV_DUMP_DIR'
    }
    $set['HV_DUMP_DIR'] = $dump
    foreach ($k in @('HV_VOL_HTML', 'HV_VOL_DB', 'HV_VOL_REDIS', 'HV_VOL_CADDY_DATA', 'HV_VOL_CADDY_CONFIG', 'HV_VOL_WGEASY')) { $set[$k] = '' }
    Write-HvOk ('Nextcloud 数据目录：' + $loc.NcData)

    # ---- logs (SPEC section 14)
    Write-HvStep '日志'
    $defLog = $loc.Base + $sep + 'logs'
    $logDir = Get-HvOpt $p 'log-dir' ''
    if (-not $logDir) {
        $logDir = Get-HvEnvDictValue $cur 'HV_LOG_DIR'
        if ($logDir -and (Test-HvWindows) -and -not (Test-HvWindowsAbsPath $logDir)) { $logDir = '' }
        if (-not $logDir) {
            $logDir = $defLog
            if (Test-HvInteractive) {
                Write-HvInfo '日志目录保存管理命令、备份、Nextcloud、访问日志和容器日志，可以在资源管理器中直接打开查看。'
                $logDir = Read-HvValue -Prompt '日志目录' -Default $defLog -Validate { param($v) (Test-HvLogDirPath $v) -and -not (Test-HvDriveRoot $v) } -ErrorText '请输入完整的文件夹路径（不能是整个盘），例如 D:\HomeVault\logs'
            }
        }
    }
    if (-not (Test-HvLogDirPath $logDir) -or ((Test-HvWindows) -and $logDir -notmatch '^[A-Za-z]:[\\/]')) { Stop-Hv ('日志目录必须是完整路径（例如 D:\HomeVault\logs）：' + $logDir) 2 }
    if (Test-HvDriveRoot $logDir) {
        if ((Get-HvOpt $p 'log-dir' '') -or $logDir -ne (Get-HvEnvDictValue $cur 'HV_LOG_DIR')) { Stop-Hv ('日志目录不能是整个盘的根目录（' + $logDir + '），请指定一个文件夹，例如 D:\HomeVault\logs') 2 }
        Write-HvWarn ('日志目录是整个盘的根目录（' + $logDir + '）：建议用 --log-dir 改为专用文件夹，例如 D:\HomeVault\logs。')
    }
    if ($logDir.Length -gt 3) { $logDir = $logDir.TrimEnd('\', '/') }
    $set['HV_LOG_DIR'] = $logDir
    $days = Get-HvOpt $p 'log-retention' ''
    if (-not $days) {
        $days = Get-HvEnvDictValue $cur 'HV_LOG_RETENTION_DAYS' '7'
        if (-not (Test-HvRetentionDays $days)) { $days = '7' }
        if ($isNew -and (Test-HvInteractive)) {
            $days = Read-HvValue -Prompt '日志保留天数（1-365；更早的日志每天自动删除，以后可在管理菜单或管理面板中修改）' -Default $days -Validate { param($v) Test-HvRetentionDays $v } -ErrorText '请输入 1 到 365 之间的整数'
        }
    }
    if (-not (Test-HvRetentionDays $days)) { Stop-Hv ('日志保留天数必须是 1-365 的整数：' + $days) 2 }
    $set['HV_LOG_RETENTION_DAYS'] = [string][int]([string]$days).Trim()
    Write-HvOk ('日志目录：' + $logDir + '（保留 ' + $set['HV_LOG_RETENTION_DAYS'] + ' 天）')
    if (Test-HvWindows) {
        foreach ($letter in @((Get-HvDriveLetterFromPath $loc.Base), (Get-HvSystemDriveLetter)) | Select-Object -Unique) {
            try {
                $dinfo = New-Object System.IO.DriveInfo($letter)
                if ($dinfo.IsReady -and $dinfo.AvailableFreeSpace -lt 20GB) {
                    Write-HvWarn ($letter + ': 只剩 ' + (ConvertTo-HvSizeText $dinfo.AvailableFreeSpace) + ' 可用空间（Docker 镜像和数据库至少需要约 20 GB）。')
                }
            } catch { }
        }
    }

    # ---- VPN
    Write-HvStep 'VPN（WireGuard for Windows）'
    $vpnOn = $true
    if (Test-HvOpt $p 'no-vpn') { $vpnOn = $false }
    elseif (-not $isNew -and -not (Test-HvTrue (Get-HvEnvDictValue $cur 'HV_VPN_ENABLED' 'true')) -and -not (Get-HvOpt $p 'wg-host' '')) { $vpnOn = $false }
    $set['HV_VPN_ENABLED'] = ([string]$vpnOn).ToLowerInvariant()
    $vpnCidr = (Get-HvCidrInfo (Get-HvInstallValue $p 'vpn-cidr' $cur 'HV_VPN_CIDR' '10.99.77.0/24')).Cidr
    if (Test-HvCidrOverlap $vpnCidr $lanCidr) { Stop-Hv ('VPN 网段 ' + $vpnCidr + ' 与局域网 ' + $lanCidr + ' 重叠：请用 --vpn-cidr 指定其他网段，例如 10.99.78.0/24') 2 }
    $set['HV_VPN_CIDR'] = $vpnCidr
    $set['HV_VPN_DNS'] = Get-HvInstallValue $p 'vpn-dns' $cur 'HV_VPN_DNS' '223.5.5.5,119.29.29.29'
    $set['HV_VPN_LAN_ACCESS'] = 'host'
    $set['HV_VPN_KEEPALIVE'] = Get-HvEnvDictValue $cur 'HV_VPN_KEEPALIVE' '0'
    if ($vpnOn) {
        $wgHost = Get-HvOpt $p 'wg-host' ''
        if (-not $wgHost) { $wgHost = Get-HvEnvDictValue $cur 'WG_HOST' }
        if (-not $wgHost) {
            $ddns = Get-HvEnvDictValue $cur 'HV_DDNS_DOMAIN'
            $pub = ''
            if (-not $ddns -and (Test-HvWindows)) { $pub = Get-HvPublicIPv4 }
            $def = $ddns; if (-not $def) { $def = $pub }
            if ($pub) { Write-HvInfo ('检测到当前公网出口 IPv4：' + $pub + '（请确认路由器 WAN 口也是这个地址，否则可能是运营商 NAT，无法从外网连入）') }
            Write-HvInfo '家庭宽带公网 IP 通常会变化，建议使用 DDNS 域名（可稍后运行 ddns setup 配置）。'
            $wgHost = Read-HvValue -Prompt 'VPN 公网地址（DDNS 域名或公网 IP）' -Default $def -Validate { param($v) Test-HvHostName $v } -ErrorText '请输入域名或 IPv4 地址'
        }
        if ($wgHost -and (Test-HvIPv4 $wgHost) -and (Test-HvIpInCidr $wgHost '100.64.0.0/10')) { Write-HvWarn ($wgHost + ' 属于运营商级 NAT 地址段：外网无法直接连入，请向运营商申请公网 IP。') }
        $set['WG_HOST'] = $wgHost
        $wgPort = Get-HvOpt $p 'wg-port' ''
        if (-not $wgPort) {
            $wgPort = Get-HvEnvDictValue $cur 'WG_PORT'
            if (-not $wgPort -or ($isNew -and $wgPort -eq '51820')) { $wgPort = [string](Get-HvRandomPort) }
        }
        if (-not (Test-HvPortNumber $wgPort)) { Stop-Hv ('WG 端口无效：' + $wgPort) 2 }
        $set['WG_PORT'] = $wgPort
        Write-HvOk ('VPN：' + $wgHost + ':' + $wgPort + '/udp，网段 ' + $vpnCidr)
    } else { Write-HvInfo '不启用 VPN（--no-vpn）：只能在局域网内访问。' }

    # ---- mirror
    $mirror = Get-HvOpt $p 'mirror' ''
    if (-not $mirror -and $isNew -and (Test-HvInteractive)) {
        if (Read-HvYesNo '是否在中国大陆网络下使用 DaoCloud 镜像拉取 Docker 镜像（Docker Hub 在大陆无法直接访问）？' $false) { $mirror = 'daocloud' }
    }
    if ($mirror) {
        $hub = Get-HvOpt $p 'mirror-hub' ''
        $ghcr = Get-HvOpt $p 'mirror-ghcr' ''
        if ($mirror -eq 'custom') {
            if (-not $hub) { $hub = Read-HvValue -Prompt 'Docker Hub 镜像前缀（例如 docker.m.daocloud.io）' -Default ((Get-HvEnvDictValue $cur 'HV_MIRROR_HUB').TrimEnd('/')) -Validate { param($v) $v -ne '' } }
            if (-not $ghcr) { $ghcr = Read-HvValue -Prompt 'ghcr.io 镜像前缀（例如 ghcr.m.daocloud.io）' -Default ((Get-HvEnvDictValue $cur 'HV_MIRROR_GHCR').TrimEnd('/')) -Validate { param($v) $v -ne '' } }
        }
        try { $pref = Get-HvMirrorPrefixes -Preset $mirror -Hub $hub -Ghcr $ghcr } catch { Stop-Hv $_.Exception.Message 2 }
        $mchg = Get-HvMirrorEnvChanges -Env $cur -Prefixes $pref
        foreach ($k in $mchg.Keys) { $set[$k] = $mchg[$k] }
        Write-HvOk ('镜像源：' + $pref.Hub + ' / ' + $pref.Ghcr)
    }

    # ---- storages (need HV_NC_DATA_PATH in .env for path checks) + backup
    $merged = [ordered]@{}
    foreach ($k in $cur.Keys) { $merged[$k] = $cur[$k] }
    foreach ($k in $set.Keys) { $merged[$k] = $set[$k] }
    $script:HvEnvCache = $merged
    Write-HvStep '额外存储（可选）'
    Read-HvInstallStorages -Parsed $p -Disks $disks
    Write-HvStep '备份目标'
    $bk = Select-HvBackupLocation -Parsed $p -Cur $cur -Disks $disks -DataBase $loc.Base
    foreach ($k in $bk.Keys) { $set[$k] = $bk[$k]; $merged[$k] = $bk[$k] }

    # ---- derived + write .env
    $wgDir = ''
    if ($vpnOn) { $wgDir = Get-HvWinWgDir }
    $derived = Get-HvDerivedEnv -Env $merged -Platform 'windows' -WinWgDir $wgDir
    foreach ($k in $derived.Keys) { $set[$k] = $derived[$k] }
    Update-HvEnv $set
    Write-HvOk ('.env 已写入：' + $envPath)

    # ---- secrets and directories
    # The kit's scripts run elevated (menu, install) and as scheduled tasks: other local accounts must not be able
    # to change them (a folder created on a secondary drive inherits "Authenticated Users: Modify").
    if ((Test-HvAdmin) -and -not (Test-HvDriveRoot $root)) {
        if (-not (Test-HvPrivateAcl $root)) { Write-HvInfo ('收紧 HomeVault 程序目录权限（仅 SYSTEM / 管理员 / 当前用户）：' + $root) }
        Set-HvPrivateAcl -Path $root
    }
    $created = @(Initialize-HvSecrets)
    if ($created.Count -gt 0) { Write-HvOk ('已生成密钥：' + ($created -join ', ')) } else { Write-HvInfo '已有密钥保持不变。' }
    foreach ($d in @($loc.Base, $loc.NcData, (Get-HvEnvValue 'HV_DUMP_DIR'))) { [void](New-HvDirectory $d) }
    # never on a whole drive (older installs may have used one): that would rewrite the ACL of every file on it
    if (-not (Test-HvDriveRoot $loc.Base)) { Set-HvPrivateAcl -Path $loc.Base } else { Set-HvPrivateAcl -Path $loc.NcData }
    if ((Get-HvEnvValue 'HV_BACKUP_TARGET') -eq 'local') {
        $bp = Get-HvEnvValue 'HV_BACKUP_LOCAL_PATH'
        [void](New-HvDirectory $bp)
        if (-not (Test-HvDriveRoot $bp)) { Set-HvPrivateAcl -Path $bp }
    }
    if ($vpnOn -and $wgDir) { [void](New-HvDirectory $wgDir) }
    Initialize-HvRuntimeDirs
    Start-HvCliLog -LogDir $logDir -CommandText 'install'
    [void](Write-HvComposeStorageFile)
    Write-HvOk 'storage.conf / compose.storage.yaml 已就绪。'

    if ($configOnly) {
        Write-HvOk '已生成配置（--config-only）：未启动服务。准备好后运行 .\windows\hv.ps1 install（或 up）。'
        return
    }

    # ---- VPN + firewall before starting (derived site list already includes the tunnel IP)
    if ($vpnOn) { Invoke-HvVpnInit } else { Invoke-HvFirewallApply }

    # ---- start
    if ((Get-HvEnvValue 'HV_TLS_MODE') -eq 'acme-dns') {
        Write-HvStep '构建带 DNS 插件的 Caddy 镜像（首次需要几分钟）...'
        [void](Invoke-HvCompose -Arguments @('build', 'caddy'))
    }
    Invoke-HvPanelBuild
    Write-HvStep '启动服务（首次需要下载镜像，可能较慢）...'
    [void](Invoke-HvCompose -Arguments @('up', '-d', '--remove-orphans'))
    [void](Wait-HvHealthy -TimeoutSec 1800)
    $probe = Invoke-HvHttpsProbe -Ip '127.0.0.1' -Port ([int](Get-HvEnvValue 'HV_HTTPS_PORT' '443')) -SniHost (Get-HvEnvValue 'HV_HOST')
    if ($probe.Ok -and $probe.Body -match '"installed"\s*:\s*true') { Write-HvOk 'HTTPS（Caddy → Nextcloud）访问正常。' }
    else { Write-HvWarn ('HTTPS 暂未就绪（' + $probe.Error + $probe.StatusLine + '）：域名模式首次申请证书可能需要几分钟，稍后运行 doctor 检查。') }
    Invoke-HvStorageSync

    # ---- backup
    $bt = Get-HvEnvValue 'HV_BACKUP_TARGET'
    if (($bt -eq 'local' -or $bt -eq 's3') -and -not (Test-HvOpt $p 'skip-backup-init')) {
        try {
            Initialize-HvResticRepo -Env (Get-HvEnv) -AllowInit $true
            if (Read-HvYesNo ('创建每日备份计划任务（每天 ' + (Get-HvEnvValue 'HV_BACKUP_TIME' '03:30') + '）？') $true) { Register-HvBackupTask -Time (Get-HvEnvValue 'HV_BACKUP_TIME' '03:30') }
        } catch { Write-HvWarn ('备份初始化未完成：' + (Get-HvErrorMessage $_) + '（稍后可运行 backup --init）') }
    }

    # ---- daily maintenance (logs, status), panel request runner, desktop shortcut "HomeVault 管理"
    Write-HvStep '计划任务与快捷方式'
    # requests first: it verifies which hidden-window mode works; the maintenance task reuses it
    Invoke-HvOptionalStep 'Register-HvRequestsTask' '管理面板请求处理任务（含 VPN 状态任务）'
    Invoke-HvOptionalStep 'Register-HvMaintenanceTask' '每日维护计划任务（导出/清理日志）'
    Invoke-HvOptionalStep 'Install-HvShortcuts' '桌面快捷方式“HomeVault 管理”'
    $apk = Join-HvPath (Join-HvPath (Get-HvPath 'state') 'app') 'homevault.apk'
    if (-not [System.IO.File]::Exists($apk) -and (Test-HvInteractive) -and (Get-Command -Name 'Invoke-HvAndroid' -CommandType Function -ErrorAction SilentlyContinue)) {
        if (Read-HvYesNo '下载 HomeVault 安卓 App 安装包（从 GitHub Release，之后手机可在管理面板“设置”页扫码安装）？' $true) {
            try { [void](Invoke-HvAndroid 'fetch') } catch { Write-HvWarn ('安卓 App 下载未完成：' + (Get-HvErrorMessage $_) + '（稍后可运行 .\windows\hv.ps1 android fetch）') }
        }
    }

    # ---- unattended start
    if (-not (Test-HvOpt $p 'skip-autostart')) { Invoke-HvAutostart }

    # ---- CA
    $ca = ''
    if ((Get-HvEnvValue 'HV_TLS_MODE') -eq 'internal') {
        $ca = Export-HvCa
        if ($ca) { Show-HvCaInstructions $ca; Install-HvCaLocal $ca } else { Write-HvWarn '暂未能导出根证书，稍后运行 .\windows\hv.ps1 ca' }
    }
    Invoke-HvOptionalStep 'Invoke-HvStatusUpdate' '状态文件（state\status.json）'
    Show-HvInstallSummary -Created $created -CaPath $ca
    if ((Test-HvWindows) -and (Test-HvInteractive)) {
        # via explorer.exe: the browser runs as the signed-in user, not elevated like this installer
        Write-HvInfo '正在浏览器中打开管理面板（用 Nextcloud 管理员账号登录）...'
        Open-HvUrl (Get-HvPanelUrl)
    }
}
