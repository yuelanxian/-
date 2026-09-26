#Requires -Version 5.1
<#
.SYNOPSIS
  HomeVault Windows 安装入口（等价于 .\windows\hv.ps1 install <参数>）。
.DESCRIPTION
  以管理员身份打开 PowerShell，在仓库根目录运行：
    powershell -ExecutionPolicy Bypass -File .\windows\install.ps1
  所有参数与 hv.ps1 install 相同，例如：--data-drive D --backup-drive E --wg-host vpn.example.com
#>
& (Join-Path $PSScriptRoot 'hv.ps1') install @args
exit $LASTEXITCODE
