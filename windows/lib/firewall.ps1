# HomeVault Windows CLI - Windows Firewall rules (LAN + VPN only) and Docker Desktop rule audit.

$script:HvFwGroup = 'HomeVault'

function Get-HvFirewallRuleSpecs {
    # Pure: the rules HomeVault manages.
    param([System.Collections.IDictionary]$Env)
    # every TCP port Docker Desktop publishes for caddy on 0.0.0.0: HTTP, HTTPS (Nextcloud), admin, management panel
    $ports = @()
    foreach ($pair in @(@('HV_HTTP_PORT', '80'), @('HV_HTTPS_PORT', '443'), @('HV_ADMIN_PORT', '8443'), @('HV_PANEL_PORT', '9443'))) {
        $v = Get-HvEnvDictValue $Env $pair[0] $pair[1]
        if ($ports -notcontains $v) { $ports += $v }
    }
    $allowed = @()
    $lan = Get-HvEnvDictValue $Env 'HV_LAN_CIDR'
    if ($lan) { $allowed += (Get-HvCidrInfo $lan).Cidr }
    $vpnOn = Test-HvTrue (Get-HvEnvDictValue $Env 'HV_VPN_ENABLED' 'true')
    $vpn = Get-HvEnvDictValue $Env 'HV_VPN_CIDR' '10.99.77.0/24'
    if ($vpnOn -and $vpn) { $allowed += (Get-HvCidrInfo $vpn).Cidr }
    $specs = @()
    $specs += [pscustomobject]@{
        Name = 'HomeVault-HTTPS'; DisplayName = 'HomeVault 网页与管理面板（仅局域网与 VPN）'; Action = 'Allow'; Protocol = 'TCP'
        LocalPort = $ports; RemoteAddress = $allowed
        Description = 'HomeVault：仅允许局域网和 VPN 网段访问 Nextcloud 与管理面板（Caddy 的 HTTP/HTTPS/管理面板端口）。由 hv.ps1 firewall 管理。'
    }
    if ($allowed.Count -gt 0) {
        $specs += [pscustomobject]@{
            Name = 'HomeVault-Block-Other'; DisplayName = 'HomeVault 阻止其他来源访问网页端口'; Action = 'Block'; Protocol = 'TCP'
            LocalPort = $ports; RemoteAddress = @(Get-HvIPv4Complement -Cidrs (@($allowed) + @('127.0.0.0/8')))
            Description = 'HomeVault：阻止局域网和 VPN 以外的来源访问 HTTP/HTTPS/管理面板端口（覆盖 Docker Desktop 自带的放行规则）。'
        }
        $specs += [pscustomobject]@{
            Name = 'HomeVault-Block-IPv6'; DisplayName = 'HomeVault 阻止 IPv6 访问网页端口'; Action = 'Block'; Protocol = 'TCP'
            LocalPort = $ports; RemoteAddress = @('::/0')
            Description = 'HomeVault：HTTP/HTTPS/管理面板端口不接受任何 IPv6 来源。'
        }
    }
    if ($vpnOn) {
        $specs += [pscustomobject]@{
            Name = 'HomeVault-WireGuard'; DisplayName = 'HomeVault WireGuard VPN'; Action = 'Allow'; Protocol = 'UDP'
            LocalPort = @((Get-HvEnvDictValue $Env 'WG_PORT' '51820')); RemoteAddress = @('Any')
            Description = 'HomeVault：WireGuard VPN 入站端口（路由器只需转发这一个 UDP 端口）。'
        }
    }
    return $specs
}

function Get-HvHomeVaultFirewallRules {
    return @(Get-NetFirewallRule -Group $script:HvFwGroup -ErrorAction SilentlyContinue)
}

function Remove-HvFirewallRules {
    foreach ($r in (Get-HvHomeVaultFirewallRules)) { Remove-NetFirewallRule -Name $r.Name -ErrorAction SilentlyContinue }
}

function Get-HvDockerFirewallRules {
    # Inbound allow rules for Docker Desktop's backend that are enabled (they may allow any source).
    $rules = @()
    try {
        $filters = @(Get-NetFirewallApplicationFilter -ErrorAction Stop | Where-Object { $_.Program -like '*com.docker.backend.exe' -or $_.Program -like '*Docker Desktop.exe' })
        foreach ($f in $filters) {
            $r = $f | Get-NetFirewallRule -ErrorAction SilentlyContinue
            foreach ($x in @($r)) {
                if ($null -ne $x -and [string]$x.Direction -eq 'Inbound' -and [string]$x.Action -eq 'Allow' -and [string]$x.Enabled -eq 'True') { $rules += $x }
            }
        }
    } catch { }
    return $rules
}

function Invoke-HvFirewallApply {
    param([switch]$DisableDockerRules)
    Assert-HvAdmin 'firewall --apply'
    $envv = Get-HvEnv
    $specs = @(Get-HvFirewallRuleSpecs -Env $envv)
    Remove-HvFirewallRules
    foreach ($s in $specs) {
        $params = @{
            Name = $s.Name; DisplayName = $s.DisplayName; Group = $script:HvFwGroup; Description = $s.Description
            Direction = 'Inbound'; Action = $s.Action; Protocol = $s.Protocol; LocalPort = $s.LocalPort
            Profile = 'Any'; Enabled = 'True'; ErrorAction = 'Stop'
        }
        if (@($s.RemoteAddress) -notcontains 'Any') { $params['RemoteAddress'] = $s.RemoteAddress }
        try {
            [void](New-NetFirewallRule @params)
        } catch {
            if ($s.Action -eq 'Block') { Write-HvWarn ('未能创建阻止规则 ' + $s.Name + '：' + $_.Exception.Message); continue }
            throw
        }
        Write-HvOk ($s.DisplayName + '：' + $s.Protocol + ' ' + (@($s.LocalPort) -join ',') + ' ← ' + (@($s.RemoteAddress) -join ', '))
    }
    $docker = @(Get-HvDockerFirewallRules)
    if ($docker.Count -gt 0) {
        Write-HvWarn ('发现 ' + $docker.Count + ' 条 Docker Desktop 的入站放行规则（可能允许任意来源）。HomeVault 的阻止规则会覆盖它们对 HTTP/HTTPS/管理面板端口的放行。')
        foreach ($d in $docker) { Write-HvInfo ('  - ' + $d.DisplayName + '（' + [string]$d.Profile + '）') }
        if ($DisableDockerRules -or (Read-HvYesNo '是否禁用这些 Docker Desktop 放行规则？（更严格；Docker 更新后可能重新出现）' $false)) {
            foreach ($d in $docker) { Disable-NetFirewallRule -Name $d.Name -ErrorAction SilentlyContinue }
            Write-HvOk '已禁用 Docker Desktop 的放行规则。'
        }
    }
}

function Show-HvFirewall {
    Assert-HvWindows 'firewall --show'
    $rules = @(Get-HvHomeVaultFirewallRules)
    if ($rules.Count -eq 0) { Write-HvWarn '没有 HomeVault 防火墙规则：请以管理员身份运行 .\windows\hv.ps1 firewall --apply' }
    foreach ($r in $rules) {
        $pf = $r | Get-NetFirewallPortFilter
        $af = $r | Get-NetFirewallAddressFilter
        Write-HvInfo ($r.DisplayName + ' [' + [string]$r.Action + ', ' + [string]$r.Enabled + '] ' + [string]$pf.Protocol + ' ' + (@($pf.LocalPort) -join ',') + ' ← ' + (@($af.RemoteAddress) -join ', '))
    }
    $docker = @(Get-HvDockerFirewallRules)
    if ($docker.Count -gt 0) {
        Write-HvWarn ('Docker Desktop 放行规则（已启用）：' + (($docker | ForEach-Object { $_.DisplayName }) -join '；'))
    }
}

function Invoke-HvCmdFirewall {
    param([object[]]$Arguments = @())
    $p = Read-HvCommandArgs -Arguments $Arguments -Switches @('apply', 'show', 'remove', 'disable-docker-rules')
    [void](Get-HvEnv)
    if (Test-HvOpt $p 'apply') { Invoke-HvFirewallApply -DisableDockerRules:(Test-HvOpt $p 'disable-docker-rules'); return }
    if (Test-HvOpt $p 'remove') {
        Assert-HvAdmin 'firewall --remove'
        Remove-HvFirewallRules
        Write-HvOk '已删除 HomeVault 防火墙规则。'
        return
    }
    Show-HvFirewall
}
