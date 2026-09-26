#Requires -Version 5.1
<#
.SYNOPSIS
  HomeVault 家庭归档服务器 - Windows 管理工具。
.DESCRIPTION
  用法：.\windows\hv.ps1 <命令> [参数]；运行 .\windows\hv.ps1 help 查看全部命令。
  如提示“禁止运行脚本”，请用：powershell -ExecutionPolicy Bypass -File .\windows\hv.ps1 <命令>
#>

$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false) } catch { }
$OutputEncoding = New-Object System.Text.UTF8Encoding($false)

$script:HvRoot = Split-Path -Parent $PSScriptRoot
$script:HvExitCode = 0
foreach ($hvLib in @(Get-ChildItem -LiteralPath (Join-Path $PSScriptRoot 'lib') -Filter '*.ps1' | Sort-Object Name)) {
    . $hvLib.FullName
}

function Show-HvHelp {
    $t = @"
HomeVault 家庭归档服务器 - Windows 管理工具 v$($script:HvVersion)
用法：.\windows\hv.ps1 <命令> [参数]      （通用参数：--yes 跳过确认；--non-interactive 不提问）

安装与运行
  install [参数]           安装或重新配置（可重复运行，不会重新生成已有密钥；需管理员）
      --host <IP|域名>        客户端访问地址（默认局域网 IP）
      --lan-ip <IP> --lan-cidr <网段>
      --data-drive <盘符>     主数据盘（数据放在 <盘符>:\HomeVault\nextcloud-data）
      --data-dir <路径>       或直接指定 HomeVault 数据根目录
      --storage "名称|路径|rw|no|用户"   额外存储（可重复）
      --backup-target local|s3|none  --backup-drive <盘符>  --backup-path <路径>
      --s3-repo <仓库> --s3-options "<restic -o 选项>"
      --wg-host <DDNS域名|公网IP> --wg-port <端口> --vpn-cidr <网段> --vpn-dns <DNS> --no-vpn
      --tls-mode internal|acme-dns --dns-provider alidns|tencentcloud|cloudflare --acme-email <邮箱>
      --mirror daocloud|custom|none [--mirror-hub <前缀> --mirror-ghcr <前缀>]
      --https-port 443 --http-port 80 --admin-port 8443 --panel-port 9443 --admin-user hvadmin
      --log-dir <路径>        日志目录（默认 <数据盘>:\HomeVault\logs）  --log-retention <天数>  日志保留天数（1-365，默认 7）
      --config-only          只生成配置，不启动；--skip-autostart；--skip-backup-init
  up [--wait] | down | restart [服务] | status | pull   （别名：start / stop / ps）
  compose <参数...>        用 HomeVault 的配置文件运行 docker compose（排查问题用，例如 compose ps）
  update [--major] [--skip-backup]   先备份，再拉取镜像并重建容器；--major 升级一个 Nextcloud 大版本
  doctor                   健康与安全检查（✔/!/✘）
  autostart                配置开机无人值守（Docker 自启、自动登录、锁屏任务、电源；需管理员）

日常管理与日志
  menu                     数字菜单（桌面快捷方式“HomeVault 管理”打开的就是它）
  logs [服务] [--follow] [--tail N]    查看容器日志（在交互窗口中默认实时跟踪，Ctrl+C 结束）
  logs list                列出日志文件（日志目录 HV_LOG_DIR）
  logs show <文件|服务> [--lines N]    显示日志内容
  logs open                在资源管理器中打开日志文件夹
  logs retention [天数]    查看或设置日志保留天数（1-365，默认 7）
  logs clean               立即删除超过保留天数的日志
  maintenance              每日维护：导出容器日志、清理过期日志、更新状态（计划任务 HomeVault-Maintenance）
  requests process         执行管理面板提交的请求（计划任务 HomeVault-Requests，每 2 分钟）
  status-update            更新管理面板读取的状态文件（state\*.json）
  android fetch            下载最新的 HomeVault 安卓 App，供手机在管理面板中下载安装

Nextcloud
  occ <参数...>            运行 Nextcloud occ 命令
  harden                   重新执行安全加固并显示关键设置
  user add <名> [--admin] [--quota 500GB] [--display-name 名字] [--email 邮箱]
  user list | user reset-2fa <名> | user reset-password <名>
  ca [--export <路径>] [--install]   导出本地根证书、显示指纹和安装方法

存储（多硬盘）
  storage list             磁盘表 + 当前存储
  storage add [--name 名称 --path E:\Photos --mode rw|ro --backup yes|no --users a,@组]
  storage remove <名称>
  storage apply            重新生成 compose.storage.yaml 并同步 Nextcloud 外部存储

VPN（WireGuard for Windows，需管理员）
  vpn init | vpn add <名称> [--no-qr] | vpn list | vpn remove <名称> | vpn qr <名称> | vpn status

DDNS
  ddns setup [--provider alidns|tencentcloud|dnspod|cloudflare|huaweicloud] [--domain 域名] | ddns status

备份与恢复（restic）
  backup [--init] [--check]            备份（--init 初始化仓库；--check 额外校验 5% 数据）
  backup --snapshots | backup --unlock 列出快照 / 清除残留的仓库锁
  restore                              列出快照
  restore --ls <路径> [--snapshot ID]  浏览快照
  restore --files <快照内路径> [--snapshot ID]   恢复到 restore\<时间>\
  restore --full [--snapshot ID]       灾难恢复（二次确认）
  schedule-backup [--time HH:MM] [--remove]      每日备份计划任务

防火墙
  firewall [--show]                 显示规则
  firewall --apply [--disable-docker-rules]   仅允许局域网与 VPN 访问 HTTP/HTTPS，放行 WireGuard UDP
  firewall --remove

其他：help | version
"@
    Write-Host $t
}

function Get-HvCommandSummary {
    # "<command> [<subcommand>]" for the CLI log (never names, paths or other values that could be sensitive).
    param([string[]]$Argv)
    $a = @($Argv)
    if ($a.Count -eq 0) { return '' }
    $t = ConvertTo-HvArgString $a[0]
    if ($a.Count -gt 1) {
        $sub = ConvertTo-HvArgString $a[1]
        if ($sub -match '^[a-z][a-z0-9-]{0,20}$') { $t += (' ' + $sub) }
    }
    return $t
}

function Set-HvGlobalSwitches {
    # Apply --yes / -y / --non-interactive without consuming them; returns the other arguments.
    param([object[]]$Arguments = @())
    $other = @()
    foreach ($a in @($Arguments)) {
        $s = ConvertTo-HvArgString $a
        if ($s -match '^(?i)--?(yes|y)$') { $script:HvYes = $true; continue }
        if ($s -match '^(?i)--?non-?interactive$') { $script:HvNonInteractive = $true; continue }
        $other += $a
    }
    return $other
}

function Get-HvExternalCommand {
    # Commands implemented by windows\lib modules that may be missing in a partial checkout.
    param([string]$Function, [string]$Command)
    $c = Get-Command -Name $Function -CommandType Function -ErrorAction SilentlyContinue
    if (-not $c) { Stop-Hv ('此版本缺少“' + $Command + '”命令的实现（' + $Function + '）：请更新 HomeVault（git pull）后重试。') }
    return $Function
}

function Invoke-HvMain {
    param([object[]]$Arguments = @())
    $argv = @($Arguments)
    if ($argv.Count -eq 0) { Show-HvHelp; return }
    $cmd = (ConvertTo-HvArgString $argv[0]).ToLowerInvariant()
    $rest = @()
    if ($argv.Count -gt 1) { $rest = @($argv[1..($argv.Count - 1)]) }
    # `requests` runs every 2 minutes: it starts the CLI log itself, only when there is work to do
    if (@('help', '-h', '--help', '/?', '-?', 'version', '--version', '-v', 'requests') -notcontains $cmd) {
        try { if (Test-HvEnvExists) { Start-HvCliLog -LogDir (Get-HvEnvLogDir) -CommandText (Get-HvCommandSummary $argv) } } catch { }
    }
    switch ($cmd) {
        { @('help', '-h', '--help', '/?', '-?') -contains $_ } { Show-HvHelp; return }
        { @('version', '--version', '-v') -contains $_ } { Write-Host ('HomeVault ' + $script:HvVersion + '（PowerShell ' + $PSVersionTable.PSVersion.ToString() + '）'); return }
        'install' { Invoke-HvCmdInstall -Arguments $rest; return }
        # aliases as in the Linux CLI: start/stop/ps/users/upgrade/check
        { @('up', 'start') -contains $_ } { Invoke-HvCmdUp -Arguments $rest; return }
        { @('down', 'stop') -contains $_ } { Invoke-HvCmdDown -Arguments $rest; return }
        'restart' { Invoke-HvCmdRestart -Arguments $rest; return }
        { @('status', 'ps') -contains $_ } { Invoke-HvCmdStatus -Arguments $rest; return }
        'compose' { Invoke-HvCmdCompose -Arguments $rest; return }
        'logs' {
            [void](Set-HvGlobalSwitches $rest)
            if (Get-Command -Name 'Invoke-HvLogs' -CommandType Function -ErrorAction SilentlyContinue) { Invoke-HvLogs @rest } else { Invoke-HvCmdLogs -Arguments $rest }
            return
        }
        'menu' { $x = @(Set-HvGlobalSwitches $rest); & (Get-HvExternalCommand 'Invoke-HvMenu' 'menu') @x; return }
        'maintenance' { $x = @(Set-HvGlobalSwitches $rest); & (Get-HvExternalCommand 'Invoke-HvMaintenance' 'maintenance') @x; return }
        'status-update' { $x = @(Set-HvGlobalSwitches $rest); & (Get-HvExternalCommand 'Invoke-HvStatusUpdate' 'status-update') @x; return }
        'requests' { [void](Set-HvGlobalSwitches $rest); & (Get-HvExternalCommand 'Invoke-HvRequests' 'requests') @rest; return }
        'android' { [void](Set-HvGlobalSwitches $rest); & (Get-HvExternalCommand 'Invoke-HvAndroid' 'android') @rest; return }
        'pull' { Invoke-HvCmdPull -Arguments $rest; return }
        { @('update', 'upgrade') -contains $_ } { Invoke-HvCmdUpdate -Arguments $rest; return }
        'occ' { Invoke-HvCmdOcc -Arguments $rest; return }
        'harden' { Invoke-HvCmdHarden -Arguments $rest; return }
        { @('user', 'users') -contains $_ } { Invoke-HvCmdUser -Arguments $rest; return }
        'ca' { Invoke-HvCmdCa -Arguments $rest; return }
        'storage' { Invoke-HvCmdStorage -Arguments $rest; return }
        'vpn' { Invoke-HvCmdVpn -Arguments $rest; return }
        'ddns' { Invoke-HvCmdDdns -Arguments $rest; return }
        'backup' { Invoke-HvCmdBackup -Arguments $rest; return }
        'restore' { Invoke-HvCmdRestore -Arguments $rest; return }
        'schedule-backup' { Invoke-HvCmdScheduleBackup -Arguments $rest; return }
        'firewall' { Invoke-HvCmdFirewall -Arguments $rest; return }
        { @('doctor', 'check') -contains $_ } { Invoke-HvCmdDoctor -Arguments $rest; return }
        'autostart' { Invoke-HvCmdAutostart -Arguments $rest; return }
        default { Stop-Hv ('未知命令：' + $cmd + '（运行 .\windows\hv.ps1 help 查看用法）') 2 }
    }
}

try {
    Invoke-HvMain -Arguments $args | Out-Host
    if ($script:HvExitCode -ne 0) { Write-HvLog ('结束，退出码 ' + $script:HvExitCode) }
} catch {
    Write-HvErr (Get-HvErrorMessage $_)
    $code = Get-HvExitCodeFromError $_
    if ($code -eq 1 -and -not ($_.Exception.Data -and $_.Exception.Data.Contains('HvExitCode'))) {
        # unexpected error: show where it happened
        Write-Host ([string]$_.InvocationInfo.PositionMessage) -ForegroundColor DarkGray
    }
    if ($code -eq 0) { $code = 1 }
    exit $code
}
exit $script:HvExitCode
