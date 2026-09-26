@echo off
rem HomeVault - management menu. Double-click this file or the desktop shortcut created by install.
rem It asks for administrator rights (UAC) and runs: powershell -File windows\hv.ps1 menu
rem Keep this file ASCII except the echo lines (UTF-8 without BOM, CRLF); chcp 65001 comes first.
setlocal EnableExtensions DisableDelayedExpansion
chcp 65001 >nul
title HomeVault

set "HV_PS=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
set "HV_SCRIPT=%~dp0hv.ps1"
if not exist "%HV_SCRIPT%" goto :missing
if not exist "%HV_PS%" goto :nopowershell

"%SystemRoot%\System32\fltmc.exe" >nul 2>&1
if not errorlevel 1 goto :run
rem Second start after UAC and still not elevated: stop instead of prompting again.
if /i "%~1"=="hv-elevated" goto :notadmin
goto :elevate

:run
"%HV_PS%" -NoProfile -ExecutionPolicy Bypass -File "%HV_SCRIPT%" menu
if errorlevel 1 goto :failed
exit /b 0

:failed
echo.
echo HomeVault 管理菜单异常退出：请阅读上面的提示。按任意键关闭本窗口。
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
echo 没有获得管理员权限，无法打开管理菜单。请重新双击，并在提示时点击“是”。
echo 按任意键关闭本窗口。
pause >nul
exit /b 1

:missing
echo 找不到 hv.ps1：HomeVault 文件不完整，请重新解压下载的压缩包。
echo 按任意键关闭本窗口。
pause >nul
exit /b 1

:nopowershell
echo 找不到 Windows PowerShell：%HV_PS%
echo 按任意键关闭本窗口。
pause >nul
exit /b 1

:notadmin
echo 仍然没有管理员权限：请右键点击“HomeVault管理.cmd”，选择“以管理员身份运行”。
echo 按任意键关闭本窗口。
pause >nul
exit /b 1
