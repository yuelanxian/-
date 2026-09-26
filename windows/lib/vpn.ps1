# HomeVault Windows CLI - VPN with WireGuard for Windows (tunnel service "homevault"), peers, QR page.

$script:HvTunnelName = 'homevault'
$script:HvTunnelService = 'WireGuardTunnel$homevault'
$script:HvWeakHostTask = 'HomeVault-WeakHost'

# ---------------------------------------------------------------- pure helpers

function Test-HvPeerName {
    # WireGuard (Android) tunnel names: [a-zA-Z0-9_=+.-]{1,15}.
    param([AllowEmptyString()][string]$Name)
    return ($Name -cmatch '^[A-Za-z0-9_=+.-]{1,15}$')
}

function ConvertFrom-HvPeersJson {
    param([AllowEmptyString()][string]$Json)
    $out = New-Object System.Collections.Generic.List[object]
    $t = ([string]$Json).Trim()
    if ($t -eq '') { return $out.ToArray() }
    $parsed = ConvertFrom-Json -InputObject $t
    foreach ($p in $parsed) {
        if ($null -eq $p) { continue }
        $out.Add([pscustomobject]@{
                name         = [string](Get-HvPropValue $p 'name' '')
                publicKey    = [string](Get-HvPropValue $p 'publicKey' '')
                presharedKey = [string](Get-HvPropValue $p 'presharedKey' '')
                address      = [string](Get-HvPropValue $p 'address' '')
                created      = [string](Get-HvPropValue $p 'created' '')
            })
    }
    return $out.ToArray()
}

function ConvertTo-HvPeersJson {
    # Deterministic JSON (no client private keys are ever stored).
    param([object[]]$Peers = @())
    $items = @()
    foreach ($p in @($Peers)) {
        $items += ('  {' + "`n" +
            '    "name": ' + (ConvertTo-HvJsonString $p.name) + ",`n" +
            '    "publicKey": ' + (ConvertTo-HvJsonString $p.publicKey) + ",`n" +
            '    "presharedKey": ' + (ConvertTo-HvJsonString $p.presharedKey) + ",`n" +
            '    "address": ' + (ConvertTo-HvJsonString $p.address) + ",`n" +
            '    "created": ' + (ConvertTo-HvJsonString $p.created) + "`n" +
            '  }')
    }
    if ($items.Count -eq 0) { return "[]`n" }
    return ("[`n" + ($items -join ",`n") + "`n]`n")
}

function New-HvWgServerConf {
    param([string]$PrivateKey, [string]$Address, [string]$ListenPort, [object[]]$Peers = @())
    $l = @(
        '# 由 HomeVault 管理（.\windows\hv.ps1 vpn ...），请勿手工编辑。'
        '[Interface]'
        ('PrivateKey = ' + $PrivateKey)
        ('Address = ' + $Address)
        ('ListenPort = ' + $ListenPort)
    )
    foreach ($p in @($Peers)) {
        $l += ''
        $l += ('# ' + $p.name + ' (' + $p.created + ')')
        $l += '[Peer]'
        $l += ('PublicKey = ' + $p.publicKey)
        if ($p.presharedKey) { $l += ('PresharedKey = ' + $p.presharedKey) }
        $l += ('AllowedIPs = ' + $p.address + '/32')
    }
    return (($l -join "`n") + "`n")
}

function Get-HvWgClientAllowedIPs {
    param([string]$VpnServerIp, [string]$LanIp)
    $a = @(($VpnServerIp + '/32'))
    if ($LanIp -and $LanIp -ne $VpnServerIp) { $a += ($LanIp + '/32') }
    return ($a -join ', ')
}

function Format-HvWgDns {
    param([AllowEmptyString()][string]$Dns)
    $parts = @(($Dns -split '[\s,]+') | Where-Object { $_ })
    return ($parts -join ', ')
}

function New-HvWgClientConf {
    param(
        [string]$PrivateKey, [string]$Address, [AllowEmptyString()][string]$Dns,
        [string]$ServerPublicKey, [AllowEmptyString()][string]$PresharedKey,
        [string]$Endpoint, [string]$AllowedIPs, [string]$Keepalive = '0'
    )
    $l = @('[Interface]', ('PrivateKey = ' + $PrivateKey), ('Address = ' + $Address + '/32'))
    $d = Format-HvWgDns $Dns
    if ($d) { $l += ('DNS = ' + $d) }
    $l += ''
    $l += '[Peer]'
    $l += ('PublicKey = ' + $ServerPublicKey)
    if ($PresharedKey) { $l += ('PresharedKey = ' + $PresharedKey) }
    $l += ('Endpoint = ' + $Endpoint)
    $l += ('AllowedIPs = ' + $AllowedIPs)
    $ka = 0
    [void][int]::TryParse([string]$Keepalive, [ref]$ka)
    if ($ka -gt 0) { $l += ('PersistentKeepalive = ' + $ka) }
    return (($l -join "`n") + "`n")
}

function Get-HvQrPageHtml {
    # Pure: fill the template (qrcode.js and the config are inlined; nothing is loaded from the network).
    param([string]$Template, [string]$QrJs, [string]$ConfigText, [string]$PeerName, [string]$Endpoint, [string]$Address, [string]$GeneratedAt)
    if ($QrJs -match '</script') { throw 'qrcode.js 内容异常。' }
    $html = $Template
    $html = $html.Replace('{{HV_QRCODE_JS}}', $QrJs)
    $html = $html.Replace('{{HV_CONFIG_JSON}}', (ConvertTo-HvJsonString $ConfigText))
    $html = $html.Replace('{{HV_FILENAME_JSON}}', (ConvertTo-HvJsonString ($PeerName + '.conf')))
    $html = $html.Replace('{{HV_PEER_NAME}}', [System.Net.WebUtility]::HtmlEncode($PeerName))
    $html = $html.Replace('{{HV_ENDPOINT}}', [System.Net.WebUtility]::HtmlEncode($Endpoint))
    $html = $html.Replace('{{HV_ADDRESS}}', [System.Net.WebUtility]::HtmlEncode($Address))
    $html = $html.Replace('{{HV_GENERATED_AT}}', [System.Net.WebUtility]::HtmlEncode($GeneratedAt))
    return $html
}

function ConvertFrom-HvWgShowDumpText {
    # Pure: `wg show <if> dump` text -> hashtable <public key> -> @{ Endpoint; Handshake; Rx; Tx } (for vpn list).
    # (state\vpn-status.json for the panel is written by status.ps1 - Update-HvVpnStatusFile.)
    param([AllowEmptyString()][string]$Text)
    $peers = @{}
    $first = $true
    foreach ($line in ($Text -split "`r?`n")) {
        if ($line -eq '') { continue }
        if ($first) { $first = $false; continue }
        $f = @($line -split "`t")
        if ($f.Count -lt 7) { continue }
        $hs = [int64]0; $rx = [int64]0; $tx = [int64]0
        [void][int64]::TryParse($f[4], [ref]$hs); [void][int64]::TryParse($f[5], [ref]$rx); [void][int64]::TryParse($f[6], [ref]$tx)
        $ep = $f[2]
        if ($ep -eq '(none)') { $ep = '' }
        $peers[$f[0]] = [pscustomobject]@{ Endpoint = $ep; Handshake = $hs; Rx = $rx; Tx = $tx }
    }
    return $peers
}

# ---------------------------------------------------------------- paths / state

function Get-HvWgPaths {
    $dir = Get-HvWinWgDir
    $pf = [System.Environment]::GetEnvironmentVariable('ProgramFiles')
    if (-not $pf) { $pf = 'C:\Program Files' }
    return [pscustomobject]@{
        Dir          = $dir
        Conf         = (Join-HvPath $dir ($script:HvTunnelName + '.conf'))
        Key          = (Join-HvPath $dir 'server.key')
        Peers        = (Join-HvPath $dir 'peers.json')
        WgExe        = (Join-HvPath $pf 'WireGuard\wg.exe')
        WireGuardExe = (Join-HvPath $pf 'WireGuard\wireguard.exe')
    }
}

function Get-HvPeers {
    $p = Get-HvWgPaths
    if (-not [System.IO.File]::Exists($p.Peers)) { return @() }
    try { return @(ConvertFrom-HvPeersJson (Read-HvTextFile $p.Peers)) } catch { Stop-Hv ('peers.json 损坏：' + $p.Peers + '（' + $_.Exception.Message + '）') }
}

function Save-HvPeers {
    param([object[]]$Peers = @())
    $p = Get-HvWgPaths
    Write-HvTextFile -Path $p.Peers -Content (ConvertTo-HvPeersJson $Peers)
}

function Test-HvWireGuardInstalled {
    $p = Get-HvWgPaths
    return ([System.IO.File]::Exists($p.WgExe) -and [System.IO.File]::Exists($p.WireGuardExe))
}

function Install-HvWireGuard {
    if (Test-HvWireGuardInstalled) { return }
    Write-HvWarn '未检测到 WireGuard for Windows。'
    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
        Stop-Hv '请先手动安装 WireGuard：https://download.wireguard.com/windows-client/wireguard-installer.exe ，安装后重新运行本命令。'
    }
    if (-not (Read-HvYesNo '现在用 winget 安装 WireGuard（WireGuard.WireGuard）？' $true)) { Stop-Hv '已取消：VPN 需要 WireGuard for Windows。' }
    [void](Invoke-HvNative -FilePath 'winget' -ArgumentList @('install', '-e', '--id', 'WireGuard.WireGuard', '--accept-package-agreements', '--accept-source-agreements') -AllowFailure)
    if (-not (Test-HvWireGuardInstalled)) { Stop-Hv 'WireGuard 安装失败：请手动安装后重试。' }
    Write-HvOk 'WireGuard 已安装。'
}

function New-HvWgKey {
    $p = Get-HvWgPaths
    $r = Invoke-HvNative -FilePath $p.WgExe -ArgumentList @('genkey') -Capture
    return $r.Text.Trim()
}

function Get-HvWgPublicKey {
    param([string]$PrivateKey)
    $p = Get-HvWgPaths
    $r = Invoke-HvNative -FilePath $p.WgExe -ArgumentList @('pubkey') -Capture -InputText $PrivateKey
    return $r.Text.Trim()
}

function New-HvWgPsk {
    $p = Get-HvWgPaths
    $r = Invoke-HvNative -FilePath $p.WgExe -ArgumentList @('genpsk') -Capture
    return $r.Text.Trim()
}

function Get-HvServerPrivateKey {
    $p = Get-HvWgPaths
    if (-not [System.IO.File]::Exists($p.Key)) { Stop-Hv 'VPN 尚未初始化：请先以管理员身份运行 .\windows\hv.ps1 vpn init' }
    return (Read-HvTextFile $p.Key).Trim()
}

function Get-HvVpnSettings {
    $envv = Get-HvEnv
    $cidr = Get-HvEnvDictValue $envv 'HV_VPN_CIDR' '10.99.77.0/24'
    $info = Get-HvCidrInfo $cidr
    $serverIp = Get-HvVpnServerIp $cidr
    return [pscustomobject]@{
        Cidr      = $info.Cidr
        Prefix    = $info.Prefix
        ServerIp  = $serverIp
        Address   = ($serverIp + '/' + $info.Prefix)
        Port      = (Get-HvEnvDictValue $envv 'WG_PORT' '51820')
        WgHost    = (Get-HvEnvDictValue $envv 'WG_HOST')
        Dns       = (Get-HvEnvDictValue $envv 'HV_VPN_DNS' '223.5.5.5,119.29.29.29')
        Keepalive = (Get-HvEnvDictValue $envv 'HV_VPN_KEEPALIVE' '0')
        LanIp     = (Get-HvEnvDictValue $envv 'HV_LAN_IP')
        LanAccess = (Get-HvEnvDictValue $envv 'HV_VPN_LAN_ACCESS' 'host')
    }
}

# ---------------------------------------------------------------- tunnel service / weak host

function Get-HvTunnelService { return (Get-Service -Name $script:HvTunnelService -ErrorAction SilentlyContinue) }

function Set-HvWeakHostNow {
    # Apply weak host send/receive on the tunnel adapter (it is recreated whenever the tunnel restarts).
    for ($i = 0; $i -lt 20; $i++) {
        $ifc = Get-NetIPInterface -InterfaceAlias $script:HvTunnelName -AddressFamily IPv4 -ErrorAction SilentlyContinue
        if ($ifc) {
            try {
                Set-NetIPInterface -InterfaceAlias $script:HvTunnelName -AddressFamily IPv4 -WeakHostReceive Enabled -WeakHostSend Enabled -ErrorAction Stop
                return $true
            } catch { }
        }
        Start-Sleep -Seconds 1
    }
    return $false
}

function Test-HvWeakHost {
    $ifc = Get-NetIPInterface -InterfaceAlias $script:HvTunnelName -AddressFamily IPv4 -ErrorAction SilentlyContinue
    if (-not $ifc) { return $false }
    return ([string]$ifc.WeakHostReceive -eq 'Enabled' -and [string]$ifc.WeakHostSend -eq 'Enabled')
}

function Register-HvWeakHostTask {
    # SYSTEM task: at startup + every 5 minutes. Inline command (no user-writable script runs as SYSTEM).
    $cmd = "Get-NetIPInterface -InterfaceAlias '" + $script:HvTunnelName + "' -AddressFamily IPv4 -ErrorAction SilentlyContinue | Set-NetIPInterface -WeakHostReceive Enabled -WeakHostSend Enabled -ErrorAction SilentlyContinue"
    # full path: a bare powershell.exe would be looked up via PATH by a SYSTEM task
    $ps = Join-HvPath ([System.Environment]::GetEnvironmentVariable('SystemRoot')) 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $action = New-ScheduledTaskAction -Execute $ps -Argument ('-NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -Command "' + $cmd + '"')
    $rep = (New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) -RepetitionInterval (New-TimeSpan -Minutes 5)).Repetition
    $t1 = New-ScheduledTaskTrigger -AtStartup
    $t1.Repetition = $rep
    $t2 = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) -RepetitionInterval (New-TimeSpan -Minutes 5)
    $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Minutes 5) -MultipleInstances IgnoreNew
    [void](Register-ScheduledTask -TaskName $script:HvWeakHostTask -Action $action -Trigger @($t1, $t2) -Principal $principal -Settings $settings `
            -Description 'HomeVault：为 WireGuard 隧道网卡 homevault 开启 WeakHostReceive/Send，使 VPN 客户端能访问本机局域网 IP。' -Force)
}

function Update-HvWgTunnel {
    # Write the server conf (private ACL), install or restart the tunnel service, re-apply weak host.
    $p = Get-HvWgPaths
    $s = Get-HvVpnSettings
    $conf = New-HvWgServerConf -PrivateKey (Get-HvServerPrivateKey) -Address $s.Address -ListenPort $s.Port -Peers (Get-HvPeers)
    Write-HvTextFile -Path $p.Conf -Content $conf
    Set-HvWgDirAcl
    $svc = Get-HvTunnelService
    if ($null -eq $svc) {
        Write-HvInfo '安装 WireGuard 隧道服务 homevault（开机自动启动，无需登录）...'
        [void](Invoke-HvNative -FilePath $p.WireGuardExe -ArgumentList @('/installtunnelservice', $p.Conf))
    } else {
        Write-HvInfo '重启 WireGuard 隧道服务以加载新配置...'
        Restart-Service -Name $script:HvTunnelService -Force -ErrorAction Stop
    }
    $ok = $false
    for ($i = 0; $i -lt 30; $i++) {
        $svc = Get-HvTunnelService
        if ($svc -and [string]$svc.Status -eq 'Running') { $ok = $true; break }
        Start-Sleep -Seconds 1
    }
    if (-not $ok) { Stop-Hv ('WireGuard 隧道服务未能启动：请运行 "' + $p.WireGuardExe + '" /dumplog /tail 查看日志。') }
    if (Set-HvWeakHostNow) { Write-HvOk '已为隧道网卡开启 Weak Host（VPN 客户端可访问本机局域网 IP）。' } else { Write-HvWarn '暂未能设置 Weak Host，计划任务 HomeVault-WeakHost 会在 5 分钟内重试。' }
    try { Start-ScheduledTask -TaskName $script:HvWeakHostTask -ErrorAction Stop } catch { }
    Save-HvVpnStatusFile
}

function Get-HvProgramDataAclArgs {
    # Pure: icacls arguments for ProgramData\HomeVault - SYSTEM + Administrators full, Users read only. (ProgramData
    # lets every user create folders, and that right is inherited by new subfolders.)
    param([string]$Path)
    return @($Path, '/inheritance:r', '/grant:r', ('*' + $script:HvSidSystem + ':(OI)(CI)F'), ('*' + $script:HvSidAdmins + ':(OI)(CI)F'), '*S-1-5-32-545:(OI)(CI)RX', '/Q')
}

function Set-HvWgDirAcl {
    # SYSTEM + Administrators full; the current user gets read so the Docker Desktop backup container can include it.
    # Administrators become the owner: an owner keeps WRITE_DAC whatever the ACL says, so a folder pre-created by
    # another local user (possible under ProgramData) would otherwise stay under that user's control.
    $p = Get-HvWgPaths
    if (-not [System.IO.Directory]::Exists($p.Dir)) { return }
    if (Test-HvWindows) {
        $parent = [System.IO.Path]::GetDirectoryName($p.Dir)
        if ($parent) { [void](Invoke-HvNative -FilePath 'icacls.exe' -ArgumentList (Get-HvProgramDataAclArgs $parent) -Capture -AllowFailure) }
        [void](Invoke-HvNative -FilePath 'icacls.exe' -ArgumentList @($p.Dir, '/setowner', ('*' + $script:HvSidAdmins), '/T', '/C', '/Q') -Capture -AllowFailure)
    }
    Set-HvPrivateAcl -Path $p.Dir -UserReadOnly
}

# ---------------------------------------------------------------- client output

function Get-HvClientsDir { return (Get-HvPath 'clients') }

function Write-HvClientConf {
    param([string]$Name, [string]$ConfText)
    $dir = New-HvDirectory (Get-HvClientsDir)
    Set-HvPrivateAcl -Path $dir
    $f = Join-HvPath $dir ($Name + '.conf')
    Write-HvTextFile -Path $f -Content $ConfText
    return $f
}

function Show-HvQrPage {
    # Write a self-contained HTML page with restricted ACL, open it, then offer to delete it.
    param([string]$Name, [string]$ConfText, [string]$Address)
    $s = Get-HvVpnSettings
    $tpl = Read-HvTextFile (Join-HvPath (Join-HvPath (Get-HvRoot) 'windows') 'templates\vpn-qr.html')
    $js = Read-HvTextFile (Join-HvPath (Join-HvPath (Get-HvRoot) 'windows') 'vendor\qrcode.js')
    $html = Get-HvQrPageHtml -Template $tpl -QrJs $js -ConfigText $ConfText -PeerName $Name -Endpoint (Format-HvEndpoint $s.WgHost $s.Port) `
        -Address $Address -GeneratedAt ((Get-Date).ToString('yyyy-MM-dd HH:mm'))
    $tmp = Join-HvPath ([System.IO.Path]::GetTempPath()) ('homevault-vpn-' + $Name + '-' + (New-HvRandomString 8) + '.html')
    Write-HvTextFile -Path $tmp -Content $html
    Set-HvPrivateAcl -Path $tmp
    Write-HvInfo ('二维码页面：' + $tmp)
    if (Test-HvWindows) {
        try { Start-Process -FilePath $tmp } catch { Write-HvWarn ('无法自动打开浏览器，请手动打开上面的文件。') }
    }
    if (Test-HvInteractive) {
        [void](Read-Host '用手机扫码导入后按回车继续')
    }
    if (Read-HvYesNo ('删除二维码页面文件（其中含私钥）？' + $tmp) $true) {
        Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
        Write-HvOk '已删除二维码页面文件。'
    } else {
        Write-HvWarn ('请在使用后手动删除：' + $tmp)
    }
}

function Show-HvClientOutput {
    param([string]$Name, [string]$ConfText, [string]$Address, [switch]$NoQr)
    $f = Write-HvClientConf -Name $Name -ConfText $ConfText
    Write-HvOk ('客户端配置已写入：' + $f + '（仅当前用户和管理员可读）')
    if (-not $NoQr) { Show-HvQrPage -Name $Name -ConfText $ConfText -Address $Address }
    if (Read-HvYesNo ('是否删除 ' + $f + '？（建议删除：私钥不会另存，需要时可用 vpn qr 重新生成）') $true) {
        Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue
        Write-HvOk '已删除客户端配置文件。'
    }
}

function New-HvClientConfForPeer {
    param($Peer, [string]$PrivateKey)
    $s = Get-HvVpnSettings
    if (-not $s.WgHost) { Stop-Hv '缺少 WG_HOST（DDNS 域名或公网 IP）：请在 .env 中设置后重试。' }
    $serverPub = Get-HvWgPublicKey (Get-HvServerPrivateKey)
    return (New-HvWgClientConf -PrivateKey $PrivateKey -Address $Peer.address -Dns $s.Dns -ServerPublicKey $serverPub `
            -PresharedKey $Peer.presharedKey -Endpoint (Format-HvEndpoint $s.WgHost $s.Port) `
            -AllowedIPs (Get-HvWgClientAllowedIPs -VpnServerIp $s.ServerIp -LanIp $s.LanIp) -Keepalive $s.Keepalive)
}

# ---------------------------------------------------------------- commands

function Invoke-HvVpnInit {
    Assert-HvAdmin 'vpn init'
    $s = Get-HvVpnSettings
    if ($s.LanAccess -eq 'full') { Write-HvWarn 'Windows 版不做 NAT：VPN 客户端只能访问本机（HV_VPN_LAN_ACCESS=full 在 Windows 上无效）。' }
    if (-not $s.WgHost) { Stop-Hv '缺少 WG_HOST：请先在 install 中设置（DDNS 域名或公网 IP）。' }
    Install-HvWireGuard
    $p = Get-HvWgPaths
    [void](New-HvDirectory $p.Dir)
    Set-HvWgDirAcl
    if (-not [System.IO.File]::Exists($p.Key)) {
        Write-HvTextFile -Path $p.Key -Content (New-HvWgKey)
        Write-HvOk '已生成服务器密钥。'
    }
    if (-not [System.IO.File]::Exists($p.Peers)) { Save-HvPeers @() }
    Set-HvWgDirAcl
    Register-HvWeakHostTask
    Write-HvOk ('计划任务 ' + $script:HvWeakHostTask + ' 已注册（SYSTEM，开机及每 5 分钟）。')
    Update-HvWgTunnel
    Update-HvDerivedEnv
    Invoke-HvFirewallApply
    Write-HvOk ('VPN 服务器已就绪：' + $s.Address + '，监听 UDP ' + $s.Port)
    Write-HvInfo ('请在路由器上把 UDP ' + $s.Port + ' 端口转发到 ' + $s.LanIp + '（只转发这一个 UDP 端口，不要开 DMZ）。')
    Write-HvInfo '然后为每台手机添加客户端：.\windows\hv.ps1 vpn add phone1'
}

function Invoke-HvVpnAdd {
    param([string]$Name, [switch]$NoQr)
    Assert-HvAdmin 'vpn add'
    if (-not (Test-HvPeerName $Name)) { Stop-Hv '客户端名称只能包含英文字母、数字和 _ = + . -，最长 15 个字符（WireGuard 隧道名限制），例如 phone-zhang。' 2 }
    $peers = @(Get-HvPeers)
    foreach ($x in $peers) { if ($x.name -ceq $Name) { Stop-Hv ('客户端 ' + $Name + ' 已存在；如需重新生成二维码请用 vpn qr ' + $Name) } }
    $s = Get-HvVpnSettings
    $used = @($s.ServerIp) + @($peers | ForEach-Object { $_.address })
    $ip = Get-HvNextFreeIp -Cidr $s.Cidr -Used $used
    $priv = New-HvWgKey
    $peer = [pscustomobject]@{ name = $Name; publicKey = (Get-HvWgPublicKey $priv); presharedKey = (New-HvWgPsk); address = $ip; created = (Get-Date).ToString('s') }
    Save-HvPeers (@($peers) + @($peer))
    Update-HvWgTunnel
    Write-HvOk ('已添加 VPN 客户端 ' + $Name + '，地址 ' + $ip)
    Show-HvClientOutput -Name $Name -ConfText (New-HvClientConfForPeer -Peer $peer -PrivateKey $priv) -Address $ip -NoQr:$NoQr
}

function Invoke-HvVpnRemove {
    param([string]$Name)
    Assert-HvAdmin 'vpn remove'
    $peers = @(Get-HvPeers)
    $keep = @($peers | Where-Object { $_.name -cne $Name })
    if ($keep.Count -eq $peers.Count) { Stop-Hv ('没有名为 ' + $Name + ' 的客户端。') }
    if (-not (Read-HvYesNo ('删除 VPN 客户端 ' + $Name + '？该设备将无法再连接') $true)) { Stop-Hv '已取消。' }
    Save-HvPeers $keep
    Update-HvWgTunnel
    $f = Join-HvPath (Get-HvClientsDir) ($Name + '.conf')
    if ([System.IO.File]::Exists($f)) { Remove-Item -LiteralPath $f -Force }
    Write-HvOk ('已删除客户端 ' + $Name)
}

function Invoke-HvVpnQr {
    param([string]$Name)
    $f = Join-HvPath (Get-HvClientsDir) ($Name + '.conf')
    $peer = $null
    foreach ($x in @(Get-HvPeers)) { if ($x.name -ceq $Name) { $peer = $x } }
    if ($null -eq $peer) { Stop-Hv ('没有名为 ' + $Name + ' 的客户端。') }
    if ([System.IO.File]::Exists($f)) {
        Show-HvQrPage -Name $Name -ConfText (Read-HvTextFile $f) -Address $peer.address
        return
    }
    Write-HvWarn '客户端私钥不会保存在服务器上，因此需要为该设备重新生成密钥（旧的配置将失效，地址不变）。'
    if (-not (Read-HvYesNo ('为 ' + $Name + ' 重新生成密钥并显示二维码？') $true)) { Stop-Hv '已取消。' }
    Assert-HvAdmin 'vpn qr（重新生成密钥）'
    $priv = New-HvWgKey
    $peers = @(Get-HvPeers)
    foreach ($x in $peers) {
        if ($x.name -ceq $Name) { $x.publicKey = (Get-HvWgPublicKey $priv); $x.presharedKey = (New-HvWgPsk); $peer = $x }
    }
    Save-HvPeers $peers
    Update-HvWgTunnel
    Show-HvClientOutput -Name $Name -ConfText (New-HvClientConfForPeer -Peer $peer -PrivateKey $priv) -Address $peer.address
}

function Get-HvWgShowDump {
    # Latest handshake per public key (needs admin); empty hashtable on failure.
    $p = Get-HvWgPaths
    if (-not (Test-HvAdmin) -or -not [System.IO.File]::Exists($p.WgExe)) { return @{} }
    $r = Invoke-HvNative -FilePath $p.WgExe -ArgumentList @('show', $script:HvTunnelName, 'dump') -Capture -AllowFailure
    if ($r.ExitCode -ne 0) { return @{} }
    return (ConvertFrom-HvWgShowDumpText ($r.Output -join "`n"))
}

function Save-HvVpnStatusFile {
    # Refresh state\vpn-status.json for the management panel after a tunnel/peer change (status.ps1).
    if (-not (Test-HvWindows)) { return }
    if (-not (Get-Command -Name 'Update-HvVpnStatusFile' -CommandType Function -ErrorAction SilentlyContinue)) { return }
    try { [void](Update-HvVpnStatusFile) } catch { Write-HvWarn ('未能更新 state\vpn-status.json：' + (Get-HvErrorMessage $_)) }
}

function Invoke-HvVpnList {
    $peers = @(Get-HvPeers)
    if ($peers.Count -eq 0) { Write-HvInfo '还没有 VPN 客户端：.\windows\hv.ps1 vpn add phone1'; return }
    $dump = Get-HvWgShowDump
    $view = @()
    $now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    foreach ($x in $peers) {
        $hs = '-'
        if ($dump.ContainsKey($x.publicKey)) {
            $d = $dump[$x.publicKey]
            if ($d.Handshake -gt 0) { $hs = ([string][int](($now - $d.Handshake) / 60)) + ' 分钟前' } else { $hs = '从未' }
        }
        $view += [pscustomobject]@{ N = $x.name; A = $x.address; C = $x.created; H = $hs }
    }
    foreach ($l in (Format-HvTable -Rows $view -Columns @('N', 'A', 'C', 'H') -Headers @('名称', 'VPN 地址', '创建时间', '最近握手'))) { Write-Host ('  ' + $l) }
    if ($dump.Count -eq 0) { Write-HvInfo '（以管理员身份运行可显示最近握手时间）' }
}

function Invoke-HvVpnStatus {
    $s = Get-HvVpnSettings
    Write-HvStep 'VPN 状态（WireGuard for Windows）'
    if (-not (Test-HvWireGuardInstalled)) { Write-HvErr '未安装 WireGuard for Windows'; return }
    $svc = Get-HvTunnelService
    if ($svc -and [string]$svc.Status -eq 'Running') { Write-HvOk ('隧道服务 ' + $script:HvTunnelService + ' 运行中（启动类型：' + [string]$svc.StartType + '）') } else { Write-HvErr '隧道服务未运行：以管理员身份运行 vpn init' }
    if (Test-HvWeakHost) { Write-HvOk 'Weak Host 已开启' } else { Write-HvWarn 'Weak Host 未开启（VPN 客户端将无法访问局域网 IP）' }
    if (Get-ScheduledTask -TaskName $script:HvWeakHostTask -ErrorAction SilentlyContinue) { Write-HvOk ('计划任务 ' + $script:HvWeakHostTask + ' 已注册') } else { Write-HvWarn ('计划任务 ' + $script:HvWeakHostTask + ' 不存在') }
    Write-HvInfo ('服务器地址：' + $s.Address + '；客户端访问：https://' + (Get-HvEnvValue 'HV_HOST' $s.LanIp))
    Write-HvInfo ('Endpoint：' + (Format-HvEndpoint $s.WgHost $s.Port) + '；路由器需转发 UDP ' + $s.Port + ' → ' + $s.LanIp)
    Invoke-HvVpnList
}

function Invoke-HvCmdVpn {
    param([object[]]$Arguments = @())
    $p = Read-HvCommandArgs -Arguments $Arguments -Switches @('no-qr')
    $sub = ''
    if ($p.Positional.Count -gt 0) { $sub = $p.Positional[0] }
    $name = ''
    if ($p.Positional.Count -gt 1) { $name = $p.Positional[1] }
    Assert-HvWindows 'vpn'
    [void](Get-HvEnv)
    if (-not (Test-HvTrue (Get-HvEnvValue 'HV_VPN_ENABLED' 'true')) -and $sub -ne 'init') {
        Write-HvWarn 'HV_VPN_ENABLED=false：安装时选择了不启用 VPN。可运行 vpn init 启用。'
    }
    switch ($sub) {
        'init' {
            if (-not (Test-HvTrue (Get-HvEnvValue 'HV_VPN_ENABLED' 'true'))) { Update-HvEnv ([ordered]@{ HV_VPN_ENABLED = 'true' }) }
            Invoke-HvVpnInit
        }
        'add' { if (-not $name) { Stop-Hv '用法：vpn add <名称>' 2 }; Invoke-HvVpnAdd -Name $name -NoQr:(Test-HvOpt $p 'no-qr') }
        'remove' { if (-not $name) { Stop-Hv '用法：vpn remove <名称>' 2 }; Invoke-HvVpnRemove -Name $name }
        'list' { Invoke-HvVpnList }
        'qr' { if (-not $name) { Stop-Hv '用法：vpn qr <名称>' 2 }; Invoke-HvVpnQr -Name $name }
        'status' { Invoke-HvVpnStatus }
        '' { Invoke-HvVpnStatus }
        default { Stop-Hv ('未知的 vpn 子命令：' + $sub + '（可用：init | add | list | remove | qr | status）') 2 }
    }
}
