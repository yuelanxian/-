# HomeVault Windows CLI - IPv4 / CIDR helpers (pure) and network detection (Windows wrappers).

function Test-HvIPv4 {
    param([AllowEmptyString()][string]$Ip)
    if ($Ip -notmatch '^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$') { return $false }
    $m = $Matches
    for ($i = 1; $i -le 4; $i++) { if ([int]$m[$i] -gt 255) { return $false } }
    return $true
}

function Test-HvDomainName {
    param([AllowEmptyString()][string]$Name)
    if ($Name.Length -gt 253) { return $false }
    if (Test-HvIPv4 $Name) { return $false }
    return ($Name -match '^(?=.{1,253}$)([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,63}$')
}

function Test-HvHostName {
    # IPv4 or a dotted DNS name or a single-label name (e.g. homevault.lan / nas).
    param([AllowEmptyString()][string]$Name)
    if (Test-HvIPv4 $Name) { return $true }
    return ($Name -match '^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?)(\.[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?)*$')
}

function ConvertTo-HvIPv4Int {
    param([string]$Ip)
    if (-not (Test-HvIPv4 $Ip)) { throw ('无效的 IPv4 地址：' + $Ip) }
    $p = $Ip -split '\.'
    return ([int64]$p[0] * 16777216) + ([int64]$p[1] * 65536) + ([int64]$p[2] * 256) + [int64]$p[3]
}

function ConvertFrom-HvIPv4Int {
    param([int64]$Value)
    if ($Value -lt 0 -or $Value -gt 4294967295) { throw ('IPv4 数值越界：' + $Value) }
    $a = [int64][Math]::Floor($Value / 16777216)
    $b = [int64][Math]::Floor(($Value % 16777216) / 65536)
    $c = [int64][Math]::Floor(($Value % 65536) / 256)
    $d = $Value % 256
    return ('{0}.{1}.{2}.{3}' -f $a, $b, $c, $d)
}

function Get-HvCidrInfo {
    param([string]$Cidr)
    if ($Cidr -notmatch '^\s*([0-9.]+)/(\d{1,2})\s*$') { throw ('无效的网段（应为 x.x.x.x/nn）：' + $Cidr) }
    $ip = $Matches[1]
    $prefix = [int]$Matches[2]
    if ($prefix -gt 32 -or -not (Test-HvIPv4 $ip)) { throw ('无效的网段：' + $Cidr) }
    $size = [int64][Math]::Pow(2, 32 - $prefix)
    $n = ConvertTo-HvIPv4Int $ip
    $net = $n - ($n % $size)
    $bcast = $net + $size - 1
    $first = $net + 1; $last = $bcast - 1
    if ($prefix -ge 31) { $first = $net; $last = $bcast }
    return [pscustomobject]@{
        Cidr         = ((ConvertFrom-HvIPv4Int $net) + '/' + $prefix)
        Network      = (ConvertFrom-HvIPv4Int $net)
        Prefix       = $prefix
        NetworkInt   = $net
        BroadcastInt = $bcast
        FirstHostInt = $first
        LastHostInt  = $last
        Size         = $size
    }
}

function Get-HvNetworkCidr {
    param([string]$Ip, [int]$Prefix)
    return (Get-HvCidrInfo ($Ip + '/' + $Prefix)).Cidr
}

function Test-HvIpInCidr {
    param([string]$Ip, [string]$Cidr)
    $info = Get-HvCidrInfo $Cidr
    $n = ConvertTo-HvIPv4Int $Ip
    return ($n -ge $info.NetworkInt -and $n -le $info.BroadcastInt)
}

function Test-HvCidrOverlap {
    param([string]$A, [string]$B)
    $x = Get-HvCidrInfo $A; $y = Get-HvCidrInfo $B
    return ($x.NetworkInt -le $y.BroadcastInt -and $y.NetworkInt -le $x.BroadcastInt)
}

function Get-HvVpnServerIp {
    # First host of the VPN subnet (e.g. 10.99.77.1 for 10.99.77.0/24).
    param([string]$Cidr)
    return (ConvertFrom-HvIPv4Int (Get-HvCidrInfo $Cidr).FirstHostInt)
}

function Get-HvNextFreeIp {
    # Next unused host address after the server address.
    param([string]$Cidr, [AllowEmptyCollection()][string[]]$Used = @())
    $info = Get-HvCidrInfo $Cidr
    $taken = New-Object 'System.Collections.Generic.HashSet[string]'
    foreach ($u in @($Used)) { if ($u) { [void]$taken.Add((($u -split '/')[0]).Trim()) } }
    for ($n = $info.FirstHostInt + 1; $n -le $info.LastHostInt; $n++) {
        $ip = ConvertFrom-HvIPv4Int $n
        if (-not $taken.Contains($ip)) { return $ip }
    }
    throw ('VPN 网段 ' + $Cidr + ' 已没有可分配的地址。')
}

function Get-HvIPv4Complement {
    # Address ranges ("a.b.c.d-e.f.g.h") covering everything outside the given CIDRs (for a firewall block rule).
    param([string[]]$Cidrs)
    $ranges = @()
    foreach ($c in @($Cidrs)) {
        if ($c) { $i = Get-HvCidrInfo $c; $ranges += [pscustomobject]@{ Start = [int64]$i.NetworkInt; End = [int64]$i.BroadcastInt } }
    }
    $sorted = @($ranges | Sort-Object -Property Start)
    $out = @()
    $cursor = [int64]0
    foreach ($r in $sorted) {
        if ($r.Start -gt $cursor) { $out += ((ConvertFrom-HvIPv4Int $cursor) + '-' + (ConvertFrom-HvIPv4Int ($r.Start - 1))) }
        if ($r.End + 1 -gt $cursor) { $cursor = $r.End + 1 }
    }
    if ($cursor -le 4294967295) { $out += ((ConvertFrom-HvIPv4Int $cursor) + '-255.255.255.255') }
    return $out
}

function Format-HvEndpoint {
    param([string]$HostName, [string]$Port)
    if ($HostName.Contains(':') -and -not $HostName.StartsWith('[')) { return ('[' + $HostName + ']:' + $Port) }
    return ($HostName + ':' + $Port)
}

# ---------------------------------------------------------------- Windows wrappers

function Get-HvLanCandidates {
    # Physical adapters with an IPv4 default gateway (the LAN), excluding Hyper-V/WSL and the VPN adapter.
    $result = @()
    if (-not (Test-HvWindows)) { return $result }
    $configs = @(Get-NetIPConfiguration -ErrorAction SilentlyContinue | Where-Object { $_.IPv4DefaultGateway -and $_.NetAdapter -and $_.NetAdapter.Status -eq 'Up' })
    foreach ($c in $configs) {
        $alias = [string]$c.InterfaceAlias
        if ($alias -like 'vEthernet*' -or $alias -eq 'homevault' -or $alias -like '*Loopback*') { continue }
        foreach ($a in @($c.IPv4Address)) {
            $ip = [string]$a.IPAddress
            if (-not (Test-HvIPv4 $ip) -or $ip.StartsWith('169.254.')) { continue }
            $result += [pscustomobject]@{
                Alias   = $alias
                Ip      = $ip
                Prefix  = [int]$a.PrefixLength
                Cidr    = (Get-HvNetworkCidr $ip ([int]$a.PrefixLength))
                Gateway = [string](@($c.IPv4DefaultGateway)[0].NextHop)
            }
        }
    }
    return $result
}

function Get-HvLocalIPv4s {
    if (-not (Test-HvWindows)) { return @() }
    return @(Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue | ForEach-Object { [string]$_.IPAddress })
}

function Get-HvPublicIPv4 {
    # Windows PowerShell 5.1 may default to TLS 1.0 only (these services require TLS 1.2).
    try { [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor [System.Net.SecurityProtocolType]::Tls12 } catch { }
    foreach ($u in @('https://4.ipw.cn', 'https://ddns.oray.com/checkip', 'https://ip.3322.net')) {
        try {
            $r = Invoke-WebRequest -Uri $u -UseBasicParsing -TimeoutSec 6
            $m = [regex]::Match([string]$r.Content, '\b(\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3})\b')
            if ($m.Success -and (Test-HvIPv4 $m.Groups[1].Value)) { return $m.Groups[1].Value }
        } catch { }
    }
    return ''
}

function Resolve-HvHostIPv4 {
    param([string]$Name)
    if (Test-HvIPv4 $Name) { return @($Name) }
    try {
        return @([System.Net.Dns]::GetHostAddresses($Name) | Where-Object { $_.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetwork } | ForEach-Object { $_.ToString() })
    } catch { return @() }
}

function Test-HvTcpPortListening {
    # Returns the owning process name(s) of IPv4/IPv6 listeners on the port (Windows only).
    param([int]$Port)
    if (-not (Test-HvWindows)) { return @() }
    $names = @()
    foreach ($c in @(Get-NetTCPConnection -State Listen -LocalPort $Port -ErrorAction SilentlyContinue)) {
        $pn = ''
        try { $pn = (Get-Process -Id $c.OwningProcess -ErrorAction Stop).ProcessName } catch { $pn = 'PID ' + $c.OwningProcess }
        if ($names -notcontains $pn) { $names += $pn }
    }
    return $names
}

function Invoke-HvHttpsProbe {
    # Raw TLS + HTTP/1.1 GET; certificate validation is skipped so it works before the CA is trusted.
    param([string]$Ip, [int]$Port, [string]$SniHost, [string]$Path = '/status.php', [int]$TimeoutMs = 8000)
    $res = [pscustomobject]@{ Ok = $false; StatusLine = ''; Body = ''; Certificate = $null; Error = '' }
    $client = $null; $ssl = $null
    try {
        $client = New-Object System.Net.Sockets.TcpClient
        $iar = $client.BeginConnect($Ip, $Port, $null, $null)
        if (-not $iar.AsyncWaitHandle.WaitOne($TimeoutMs)) { throw ('连接 ' + $Ip + ':' + $Port + ' 超时') }
        $client.EndConnect($iar)
        $client.ReceiveTimeout = $TimeoutMs; $client.SendTimeout = $TimeoutMs
        $cb = [System.Net.Security.RemoteCertificateValidationCallback] { param($s, $c, $ch, $e) return $true }
        $ssl = New-Object System.Net.Security.SslStream($client.GetStream(), $false, $cb)
        $target = $SniHost
        if (-not $target) { $target = $Ip }
        $ssl.AuthenticateAsClient($target, $null, [System.Security.Authentication.SslProtocols]::Tls12, $false)
        if ($ssl.RemoteCertificate) { $res.Certificate = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2($ssl.RemoteCertificate) }
        $hostHeader = $target
        if ($Port -ne 443) { $hostHeader = $target + ':' + $Port }
        $req = 'GET ' + $Path + " HTTP/1.1`r`nHost: " + $hostHeader + "`r`nUser-Agent: homevault-cli`r`nConnection: close`r`n`r`n"
        $bytes = [System.Text.Encoding]::ASCII.GetBytes($req)
        $ssl.Write($bytes, 0, $bytes.Length); $ssl.Flush()
        $ms = New-Object System.IO.MemoryStream
        $buf = New-Object byte[] 8192
        while ($true) {
            $n = 0
            try { $n = $ssl.Read($buf, 0, $buf.Length) } catch { break }
            if ($n -le 0) { break }
            $ms.Write($buf, 0, $n)
            if ($ms.Length -gt 1048576) { break }
        }
        $text = [System.Text.Encoding]::UTF8.GetString($ms.ToArray())
        $res.StatusLine = (($text -split "`r?`n")[0])
        $idx = $text.IndexOf("`r`n`r`n")
        if ($idx -ge 0) { $res.Body = $text.Substring($idx + 4) }
        $res.Ok = ($res.StatusLine -match '^HTTP/1\.[01] 200')
    } catch {
        $res.Error = $_.Exception.Message
    } finally {
        if ($ssl) { $ssl.Dispose() }
        if ($client) { $client.Close() }
    }
    return $res
}
