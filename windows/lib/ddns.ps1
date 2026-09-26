# HomeVault Windows CLI - DDNS via the ddns-go container (profile "ddns", -noweb, generated config).

$script:HvDdnsProviders = @('alidns', 'tencentcloud', 'dnspod', 'cloudflare', 'huaweicloud')

function New-HvDdnsGoYaml {
    # Pure: full ddns-go config (IPv4 via URL; IPv6 off; web UI disabled by -noweb).
    param([string]$Provider, [AllowEmptyString()][string]$Id, [string]$Secret, [string[]]$Domains, [string]$Ttl = '600')
    if ($script:HvDdnsProviders -notcontains $Provider) { throw ('不支持的 DNS 服务商：' + $Provider) }
    $l = @(
        '# 由 HomeVault 生成（hv ddns setup），包含 DNS API 密钥，请勿外传。'
        'dnsconf:'
        '    - name: homevault'
        '      ipv4:'
        '        enable: true'
        '        gettype: url'
        '        url: https://ddns.oray.com/checkip, https://4.ipw.cn'
        '        domains:'
    )
    foreach ($d in @($Domains)) { $l += ('            - ' + (ConvertTo-HvYamlSingleQuoted $d)) }
    $l += @(
        '      ipv6:'
        '        enable: false'
        '      dns:'
        ('        name: ' + $Provider)
        ('        id: ' + (ConvertTo-HvYamlSingleQuoted $Id))
        ('        secret: ' + (ConvertTo-HvYamlSingleQuoted $Secret))
        ('      ttl: ' + (ConvertTo-HvYamlSingleQuoted $Ttl))
        'notallowwanaccess: true'
    )
    return (($l -join "`n") + "`n")
}

function Invoke-HvDdnsSetup {
    param([hashtable]$Parsed)
    $provider = Get-HvOpt $Parsed 'provider' (Get-HvEnvValue 'HV_DDNS_PROVIDER' '')
    if (-not $provider) {
        $provider = Read-HvValue -Prompt ('DNS 服务商（' + ($script:HvDdnsProviders -join ' / ') + '）') -Default 'alidns' -Validate { param($v) $script:HvDdnsProviders -contains $v }
    }
    if ($script:HvDdnsProviders -notcontains $provider) { Stop-Hv ('不支持的 DNS 服务商：' + $provider) 2 }
    $domain = Get-HvOpt $Parsed 'domain' (Get-HvEnvValue 'HV_DDNS_DOMAIN' '')
    if (-not $domain) {
        $domain = Read-HvValue -Prompt 'DDNS 域名（解析到家里公网 IP，例如 vpn.example.com）' -Default (Get-HvEnvValue 'WG_HOST' '') -Validate { param($v) Test-HvDomainName $v }
    }
    if (-not (Test-HvDomainName $domain)) { Stop-Hv ('域名无效：' + $domain) 2 }
    $id = ''
    if ($provider -ne 'cloudflare') {
        $idLabel = 'AccessKey ID'
        if ($provider -eq 'tencentcloud') { $idLabel = 'SecretId' } elseif ($provider -eq 'dnspod') { $idLabel = 'ID' } elseif ($provider -eq 'huaweicloud') { $idLabel = 'Access Key Id' }
        $id = Read-HvSecretValue -Prompt ($idLabel + '（建议使用只允许修改该域名解析的子账号）') -EnvName 'HV_DDNS_ID'
    }
    $secLabel = 'AccessKey Secret'
    if ($provider -eq 'cloudflare') { $secLabel = 'API Token（仅授予该域名 Zone:DNS:Edit）' } elseif ($provider -eq 'tencentcloud') { $secLabel = 'SecretKey' } elseif ($provider -eq 'dnspod') { $secLabel = 'Token' } elseif ($provider -eq 'huaweicloud') { $secLabel = 'Secret Access Key' }
    $secret = Read-HvSecretValue -Prompt $secLabel -EnvName 'HV_DDNS_SECRET'
    [void](Initialize-HvSecretsDir)
    Write-HvTextFile -Path (Get-HvSecretPath 'ddns-go.yaml') -Content (New-HvDdnsGoYaml -Provider $provider -Id $id -Secret $secret -Domains @($domain))
    Set-HvPrivateAcl -Path (Get-HvSecretsDir)
    $vals = [ordered]@{ HV_DDNS_ENABLED = 'true'; HV_DDNS_PROVIDER = $provider; HV_DDNS_DOMAIN = $domain }
    $wg = Get-HvEnvValue 'WG_HOST' ''
    if (-not $wg -or ((Test-HvIPv4 $wg) -and (Read-HvYesNo ('把 VPN Endpoint（WG_HOST）从 ' + $wg + ' 改为 ' + $domain + '？') $true))) { $vals['WG_HOST'] = $domain }
    Update-HvEnv $vals
    Write-HvOk ('已写入 secrets\ddns-go.yaml（' + $provider + '，' + $domain + '）')
    if ($vals.Contains('WG_HOST')) { Write-HvWarn '注意：已存在的 VPN 客户端配置里的 Endpoint 不会自动改变，请用 vpn qr <名称> 重新生成。' }
    if (Get-Command docker -ErrorAction SilentlyContinue) {
        Write-HvStep '启动 ddns-go ...'
        [void](Invoke-HvCompose -Arguments @('up', '-d', 'ddns-go') -AllowFailure)
    } else {
        Write-HvWarn '未找到 docker 命令：启动 Docker Desktop 后运行 .\windows\hv.ps1 up 即可启用 ddns-go。'
    }
}

function Invoke-HvDdnsStatus {
    $on = Test-HvTrue (Get-HvEnvValue 'HV_DDNS_ENABLED' 'false')
    $domain = Get-HvEnvValue 'HV_DDNS_DOMAIN' ''
    if (-not $on) { Write-HvWarn 'DDNS 未启用：运行 .\windows\hv.ps1 ddns setup' ; return }
    Write-HvInfo ('服务商：' + (Get-HvEnvValue 'HV_DDNS_PROVIDER') + '；域名：' + $domain)
    $st = Get-HvServiceState -Rows (Get-HvComposePs) -Service 'ddns-go'
    if ($st -and $st.State -eq 'running') { Write-HvOk 'ddns-go 容器运行中' } else { Write-HvErr 'ddns-go 容器未运行' }
    $pub = Get-HvPublicIPv4
    $res = @(Resolve-HvHostIPv4 $domain)
    if ($pub) { Write-HvInfo ('当前公网 IPv4：' + $pub) }
    if ($res.Count -gt 0) { Write-HvInfo ('域名解析结果：' + ($res -join ', ')) }
    if ($pub -and $res -contains $pub) { Write-HvOk '域名已指向当前公网 IP。' } elseif ($pub -and $res.Count -gt 0) { Write-HvWarn '域名尚未指向当前公网 IP（DNS 缓存/TTL 可能需要几分钟）。' }
    if ($pub -and ($pub.StartsWith('100.') -and (Test-HvIpInCidr $pub '100.64.0.0/10'))) { Write-HvWarn '公网出口 IP 属于运营商级 NAT（100.64.0.0/10）：没有公网 IPv4，端口转发无效。' }
    Write-HvStep 'ddns-go 最近日志'
    [void](Invoke-HvCompose -Arguments @('logs', '--tail', '20', 'ddns-go') -AllowFailure)
}

function Invoke-HvCmdDdns {
    param([object[]]$Arguments = @())
    $p = Read-HvCommandArgs -Arguments $Arguments -Options @('provider', 'domain')
    [void](Get-HvEnv)
    $sub = 'status'
    if ($p.Positional.Count -gt 0) { $sub = $p.Positional[0] }
    switch ($sub) {
        'setup' { Invoke-HvDdnsSetup -Parsed $p }
        'status' { Invoke-HvDdnsStatus }
        default { Stop-Hv '用法：ddns setup [--provider alidns] [--domain vpn.example.com] | ddns status' 2 }
    }
}
