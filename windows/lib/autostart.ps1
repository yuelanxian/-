# HomeVault Windows CLI - unattended start: Docker Desktop at sign-in, Autologon, lock task, power settings.

$script:HvLockTask = 'HomeVault-Lock'

function Get-HvDockerDesktopExe {
    $cands = @()
    $pf = [System.Environment]::GetEnvironmentVariable('ProgramFiles')
    $la = [System.Environment]::GetEnvironmentVariable('LOCALAPPDATA')
    if ($pf) { $cands += (Join-HvPath $pf 'Docker\Docker\Docker Desktop.exe') }
    if ($la) { $cands += (Join-HvPath $la 'Programs\DockerDesktop\Docker Desktop.exe') }
    foreach ($c in $cands) { if ([System.IO.File]::Exists($c)) { return $c } }
    return ''
}

function Get-HvAutostartState {
    $s = [pscustomobject]@{ DockerAutostart = $false; Autologon = $false; AutologonUser = ''; LockTask = $false; DockerExe = '' }
    if (-not (Test-HvWindows)) { return $s }
    $s.DockerExe = Get-HvDockerDesktopExe
    try {
        $run = Get-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' -ErrorAction Stop
        foreach ($p in $run.PSObject.Properties) { if ($p.Name -like '*Docker Desktop*' -or ([string]$p.Value -like '*Docker Desktop.exe*')) { $s.DockerAutostart = $true } }
    } catch { }
    if (-not $s.DockerAutostart) {
        $appdata = [System.Environment]::GetEnvironmentVariable('APPDATA')
        foreach ($f in @('Docker\settings-store.json', 'Docker\settings.json')) {
            $pth = Join-HvPath $appdata $f
            if ($appdata -and [System.IO.File]::Exists($pth)) {
                try {
                    $j = ConvertFrom-Json -InputObject (Read-HvTextFile $pth)
                    if ((Test-HvTrue (Get-HvPropValue $j 'AutoStart' $false)) -or (Test-HvTrue (Get-HvPropValue $j 'autoStart' $false))) { $s.DockerAutostart = $true }
                } catch { }
            }
        }
    }
    try {
        $wl = Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon' -ErrorAction Stop
        if ([string](Get-HvPropValue $wl 'AutoAdminLogon' '') -eq '1') { $s.Autologon = $true; $s.AutologonUser = [string](Get-HvPropValue $wl 'DefaultUserName' '') }
    } catch { }
    if (Get-ScheduledTask -TaskName $script:HvLockTask -ErrorAction SilentlyContinue) { $s.LockTask = $true }
    return $s
}

function Register-HvLockTask {
    $user = Get-HvDesktopUserName
    $action = New-ScheduledTaskAction -Execute 'rundll32.exe' -Argument 'user32.dll,LockWorkStation'
    $trigger = New-ScheduledTaskTrigger -AtLogOn -User $user
    $principal = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Limited
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
    [void](Register-ScheduledTask -TaskName $script:HvLockTask -Action $action -Trigger $trigger -Principal $principal -Settings $settings `
            -Description 'HomeVault：自动登录后立即锁屏（Docker Desktop 仍会在后台启动）。' -Force)
    Write-HvOk ('已创建计划任务 ' + $script:HvLockTask + '：' + $user + ' 登录后自动锁屏。')
}

function Set-HvPowerNoSleep {
    foreach ($a in @(@('/change', 'standby-timeout-ac', '0'), @('/change', 'hibernate-timeout-ac', '0'), @('/change', 'disk-timeout-ac', '0'))) {
        [void](Invoke-HvNative -FilePath 'powercfg.exe' -ArgumentList $a -Capture -AllowFailure)
    }
    Write-HvOk '已设置：接通电源时从不睡眠、从不休眠、硬盘从不关闭。'
}

function Invoke-HvAutostart {
    # Interactive guidance; each change asks first (skipped with --yes where safe).
    param([switch]$SkipPower)
    Assert-HvWindows 'autostart'
    $st = Get-HvAutostartState
    Write-HvStep '开机无人值守启动'
    Write-HvInfo '启动顺序：开机 → WireGuard 隧道服务（无需登录）→ 自动登录 → 锁屏 → Docker Desktop 启动 → 容器按 restart: unless-stopped 自动恢复。'
    if ($st.DockerAutostart) { Write-HvOk 'Docker Desktop 已设置为登录后自动启动。' }
    else {
        Write-HvWarn 'Docker Desktop 未设置为登录后自动启动。'
        Write-HvInfo '请打开 Docker Desktop → Settings（齿轮）→ General → 勾选 “Start Docker Desktop when you sign in to your computer” → Apply。'
    }
    if ($st.Autologon) { Write-HvOk ('已配置自动登录（用户 ' + $st.AutologonUser + '）。') }
    else {
        Write-HvWarn 'Docker Desktop 必须有用户登录才会运行：停电/重启后如果无人登录，Nextcloud 就不可用。'
        Write-HvInfo '推荐：使用微软官方的 Sysinternals Autologon 配置自动登录（密码以 LSA 机密加密保存；开机时按住 Shift 可跳过）。'
        Write-HvInfo '建议为 HomeVault 使用一个专用的本地账户（加入 docker-users 组），并在该账户下运行 Docker Desktop。'
        $exe = @(Get-Command 'autologon64.exe', 'autologon.exe' -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1)
        if ($exe.Count -eq 0 -and (Get-Command winget -ErrorAction SilentlyContinue)) {
            if (Read-HvYesNo '现在用 winget 安装 Sysinternals Autologon？' $true) {
                [void](Invoke-HvNative -FilePath 'winget' -ArgumentList @('install', '-e', '--id', 'Microsoft.Sysinternals.Autologon', '--accept-package-agreements', '--accept-source-agreements') -AllowFailure)
                $exe = @(Get-Command 'autologon64.exe', 'autologon.exe' -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1)
            }
        }
        if ($exe.Count -gt 0) {
            if (Read-HvYesNo '现在打开 Autologon 设置窗口？（在窗口中输入用户名和密码，点 Enable）' $true) {
                try { Start-Process -FilePath $exe[0].Path -Wait } catch { Write-HvWarn ('无法启动 Autologon：' + $_.Exception.Message) }
            }
        } else {
            Write-HvInfo '手动下载：https://learn.microsoft.com/sysinternals/downloads/autologon'
        }
        $st = Get-HvAutostartState
    }
    if (-not $st.LockTask) {
        if (Read-HvYesNo ('创建计划任务 ' + $script:HvLockTask + '：登录后立即锁屏（配合自动登录使用）？') $st.Autologon) { Register-HvLockTask }
    } else { Write-HvOk ('锁屏任务 ' + $script:HvLockTask + ' 已存在。') }
    if (-not $SkipPower) {
        if (Read-HvYesNo '把电源计划设为“接通电源时从不睡眠/休眠”？（服务器需要一直在线）' $true) { Set-HvPowerNoSleep }
    }
    Write-HvInfo '另外建议：在 BIOS/UEFI 中把 “Restore on AC Power Loss / 断电恢复” 设为 Power On（来电自动开机）；如使用 BitLocker 启动 PIN，无人值守开机会停在 PIN 界面。'
    Write-HvInfo 'Windows 更新：把“使用时段”设为最大范围，重启后以上链路会自动恢复服务。'
}

function Invoke-HvCmdAutostart {
    param([object[]]$Arguments = @())
    $p = Read-HvCommandArgs -Arguments $Arguments -Switches @('skip-power')
    Assert-HvAdmin 'autostart'
    Invoke-HvAutostart -SkipPower:(Test-HvOpt $p 'skip-power')
}
