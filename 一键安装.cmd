@echo off
rem HomeVault - one-click install / reconfigure for Windows 10/11. Double-click this file.
rem It asks for administrator rights (UAC) and runs: powershell -File windows\hv.ps1 install
rem Keep this file ASCII except the echo lines (UTF-8 without BOM, CRLF); chcp 65001 comes first.
setlocal EnableExtensions DisableDelayedExpansion
chcp 65001 >nul
title HomeVault

set "HV_PS=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
set "HV_SCRIPT=%~dp0windows\hv.ps1"
if not exist "%HV_SCRIPT%" goto :missing
if not exist "%HV_PS%" goto :nopowershell

"%SystemRoot%\System32\fltmc.exe" >nul 2>&1
if not errorlevel 1 goto :run
rem Second start after UAC and still not elevated: stop instead of prompting again.
if /i "%~1"=="hv-elevated" goto :notadmin
goto :elevate

:run
echo.
echo ================ HomeVault 家庭归档服务器 - 一键安装 ================
echo 按提示回答几个问题即可（直接回车 = 使用推荐的默认值）。可以重复运行，已有数据和密码不会丢失。
echo.
"%HV_PS%" -NoProfile -ExecutionPolicy Bypass -File "%HV_SCRIPT%" install
if errorlevel 1 goto :failed
echo.
echo 安装程序已结束。请确认已把上面显示的密码抄写保存好，然后按任意键关闭本窗口。
echo 以后管理服务器：双击桌面上的“HomeVault 管理”。
pause >nul
exit /b 0

:failed
echo.
echo 安装没有完成：请阅读上面的提示，处理后重新双击“一键安装.cmd”（可以重复运行）。
echo 按任意键关闭本窗口。
pause >nul
exit /b 1

:elevate
echo 需要管理员权限：请在弹出的“用户账户控制”窗口中点击“是”。
set "HV_SELF=%~f0"
"%HV_PS%" -NoProfile -ExecutionPolicy Bypass -Command "$q = [char]34; try { Start-Process -FilePath $env:ComSpec -ArgumentList ('/c ' + $q + $q + $env:HV_SELF + $q + ' hv-elevated' + $q) -Verb RunAs -ErrorAction Stop } catch { exit 1 }"
if errorlevel 1 goto :denied
exit /b 0

:denied
echo.
echo 没有获得管理员权限，安装无法继续。请重新双击“一键安装.cmd”，并在提示时点击“是”。
echo 按任意键关闭本窗口。
pause >nul
exit /b 1

:missing
echo 找不到 windows\hv.ps1：请先把下载的压缩包完整解压到一个文件夹，例如 D:\HomeVault，再双击其中的“一键安装.cmd”。
echo 按任意键关闭本窗口。
pause >nul
exit /b 1

:nopowershell
echo 找不到 Windows PowerShell：%HV_PS%
echo 按任意键关闭本窗口。
pause >nul
exit /b 1

:notadmin
echo 仍然没有管理员权限：请右键点击“一键安装.cmd”，选择“以管理员身份运行”。
echo 按任意键关闭本窗口。
pause >nul
exit /b 1
