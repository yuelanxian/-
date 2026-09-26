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
      --https-port 443 --http-port 80 --admin-port 8443 --admin-user hvadmin
      --config-only          只生成配置，不启动；--skip-autostart；--skip-backup-init
  up [--wait] | down | restart [服务] | status | logs [服务] [--follow] [--tail N] | pull
  update [--major] [--skip-backup]   先备份，再拉取镜像并重建容器；--major 升级一个 Nextcloud 大版本
  doctor                   健康与安全检查（✔/!/✘）
  autostart                配置开机无人值守（Docker 自启、自动登录、锁屏任务、电源；需管理员）

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

function Invoke-HvMain {
    param([object[]]$Arguments = @())
    $argv = @($Arguments)
    if ($argv.Count -eq 0) { Show-HvHelp; return }
    $cmd = (ConvertTo-HvArgString $argv[0]).ToLowerInvariant()
    $rest = @()
    if ($argv.Count -gt 1) { $rest = $argv[1..($argv.Count - 1)] }
    switch ($cmd) {
        { @('help', '-h', '--help', '/?', '-?') -contains $_ } { Show-HvHelp; return }
        { @('version', '--version', '-v') -contains $_ } { Write-Host ('HomeVault ' + $script:HvVersion + '（PowerShell ' + $PSVersionTable.PSVersion.ToString() + '）'); return }
        'install' { Invoke-HvCmdInstall -Arguments $rest; return }
        'up' { Invoke-HvCmdUp -Arguments $rest; return }
        'down' { Invoke-HvCmdDown -Arguments $rest; return }
        'restart' { Invoke-HvCmdRestart -Arguments $rest; return }
        'status' { Invoke-HvCmdStatus -Arguments $rest; return }
        'logs' { Invoke-HvCmdLogs -Arguments $rest; return }
        'pull' { Invoke-HvCmdPull -Arguments $rest; return }
        'update' { Invoke-HvCmdUpdate -Arguments $rest; return }
        'occ' { Invoke-HvCmdOcc -Arguments $rest; return }
        'harden' { Invoke-HvCmdHarden -Arguments $rest; return }
        'user' { Invoke-HvCmdUser -Arguments $rest; return }
        'ca' { Invoke-HvCmdCa -Arguments $rest; return }
        'storage' { Invoke-HvCmdStorage -Arguments $rest; return }
        'vpn' { Invoke-HvCmdVpn -Arguments $rest; return }
        'ddns' { Invoke-HvCmdDdns -Arguments $rest; return }
        'backup' { Invoke-HvCmdBackup -Arguments $rest; return }
        'restore' { Invoke-HvCmdRestore -Arguments $rest; return }
        'schedule-backup' { Invoke-HvCmdScheduleBackup -Arguments $rest; return }
        'firewall' { Invoke-HvCmdFirewall -Arguments $rest; return }
        'doctor' { Invoke-HvCmdDoctor -Arguments $rest; return }
        'autostart' { Invoke-HvCmdAutostart -Arguments $rest; return }
        default { Stop-Hv ('未知命令：' + $cmd + '（运行 .\windows\hv.ps1 help 查看用法）') 2 }
    }
}

try {
    Invoke-HvMain -Arguments $args | Out-Host
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
