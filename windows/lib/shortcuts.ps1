# HomeVault Windows CLI - desktop integration (SPEC sections 14, 15, 17): "HomeVault 管理" shortcuts and the
# scheduled tasks HomeVault-Maintenance (daily 04:00), HomeVault-Requests (every 2 minutes) and
# HomeVault-VpnStatus (SYSTEM, every 2 minutes, WireGuard handshakes/traffic without keys).

$script:HvMaintenanceTask = 'HomeVault-Maintenance'
$script:HvRequestsTask = 'HomeVault-Requests'
$script:HvVpnStatusTask = 'HomeVault-VpnStatus'
$script:HvShortcutName = 'HomeVault 管理'
$script:HvManageCmdName = 'HomeVault管理.cmd'
$script:HvTaskHeadless = $null

# ---------------------------------------------------------------- pure helpers

function Get-HvShortcutPlan {
    # Pure: the .lnk files to create (desktop + Start menu), all pointing at windows\HomeVault管理.cmd.
    param([string]$Root, [string]$DesktopDir = '', [string]$ProgramsDir = '', [string]$IconLocation = '')
    $sep = '\'
    if ($Root.StartsWith('/')) { $sep = '/' }
    $r = $Root.TrimEnd('\', '/')
    $target = $r + $sep + 'windows' + $sep + $script:HvManageCmdName
    $items = @()
    foreach ($d in @($DesktopDir, $ProgramsDir)) {
        if (-not $d) { continue }
        $items += [pscustomobject]@{
            Path             = ($d.TrimEnd('\', '/') + $sep + $script:HvShortcutName + '.lnk')
            Target           = $target
            WorkingDirectory = $r
            Description      = 'HomeVault 家庭归档服务器：管理菜单（状态、日志、手机 VPN、备份、存储、用户）'
            IconLocation     = $IconLocation
        }
    }
    return $items
}

function Get-HvHiddenTaskAction {
    # Pure: Task Scheduler action running `hv.ps1 <args>` without a console window flashing every run:
    # conhost.exe --headless (Windows 10 2004+/11), else powershell -WindowStyle Hidden (may flash briefly).
    param([string]$SystemRoot, [string]$HvScript, [string[]]$HvArgs = @(), [bool]$Headless = $true)
    $ps = $SystemRoot.TrimEnd('\') + '\System32\WindowsPowerShell\v1.0\powershell.exe'
    $psArgs = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + $HvScript + '"'
    $rest = ConvertTo-HvCommandLine @($HvArgs)
    if ($rest) { $psArgs += ' ' + $rest }
    if ($Headless) {
        return [pscustomobject]@{ Execute = ($SystemRoot.TrimEnd('\') + '\System32\conhost.exe'); Argument = ('--headless "' + $ps + '" ' + $psArgs) }
    }
    return [pscustomobject]@{ Execute = $ps; Argument = $psArgs }
}

function Get-HvVpnStatusScript {
    # Script run by the SYSTEM task HomeVault-VpnStatus (embedded in the task via -EncodedCommand, so nothing
    # user-writable runs as SYSTEM). Writes ProgramData\HomeVault\wireguard\vpn-status.json: device names and
    # addresses from peers.json + handshake/traffic from `wg.exe show homevault dump`. Never writes keys.
    return @'
$ErrorActionPreference = 'SilentlyContinue'
$hvDir = Join-Path $env:ProgramData 'HomeVault\wireguard'
$hvWg = Join-Path $env:ProgramFiles 'WireGuard\wg.exe'
if (Test-Path -LiteralPath $hvDir) {
    function HvJ([string]$s) { return ('"' + (($s -replace '\\', '\\') -replace '"', '\"' -replace '[\x00-\x1f]', '') + '"') }
    $hvPeers = @{}
    $hvPf = Join-Path $hvDir 'peers.json'
    if (Test-Path -LiteralPath $hvPf) {
        $hvList = ConvertFrom-Json ([System.IO.File]::ReadAllText($hvPf))
        foreach ($p in $hvList) { if ($p.publicKey) { $hvPeers[[string]$p.publicKey] = $p } }
    }
    $hvLines = @()
    $hvOk = $false
    if (Test-Path -LiteralPath $hvWg) {
        $hvLines = @(& $hvWg show homevault dump 2>$null)
        $hvOk = ($LASTEXITCODE -eq 0 -and $hvLines.Count -gt 0)
    }
    $hvItems = @()
    $hvPort = 0
    if ($hvOk) {
        $f0 = @($hvLines[0] -split "`t")
        if ($f0.Count -ge 3) { [void][int]::TryParse($f0[2], [ref]$hvPort) }
        for ($i = 1; $i -lt $hvLines.Count; $i++) {
            $f = @($hvLines[$i] -split "`t")
            if ($f.Count -lt 7 -or -not $hvPeers.ContainsKey($f[0])) { continue }
            $p = $hvPeers[$f[0]]
            $hs = [int64]0; $rx = [int64]0; $tx = [int64]0
            [void][int64]::TryParse($f[4], [ref]$hs); [void][int64]::TryParse($f[5], [ref]$rx); [void][int64]::TryParse($f[6], [ref]$tx)
            $item = '{"name":' + (HvJ ([string]$p.name)) + ',"address":' + (HvJ ([string]$p.address + '/32')) + ',"enabled":true,"latest_handshake":' + $hs + ',"rx_bytes":' + $rx + ',"tx_bytes":' + $tx
            if ($f[2] -and $f[2] -ne '(none)') { $item += ',"endpoint":' + (HvJ $f[2]) }
            $hvItems += ($item + '}')
        }
    }
    $hvNow = (Get-Date).ToString("yyyy-MM-dd'T'HH:mm:sszzz", [System.Globalization.CultureInfo]::InvariantCulture)
    $hvJson = '{"updated":' + (HvJ $hvNow) + ',"platform":"windows","interface":"homevault","listen_port":' + $hvPort + ',"tunnel_ok":' + ([string]$hvOk).ToLowerInvariant() + ',"peers":[' + ($hvItems -join ',') + ']}'
    $hvTmp = Join-Path $hvDir 'vpn-status.json.tmp'
    [System.IO.File]::WriteAllText($hvTmp, $hvJson + "`n", (New-Object System.Text.UTF8Encoding($false)))
    Move-Item -LiteralPath $hvTmp -Destination (Join-Path $hvDir 'vpn-status.json') -Force
}
'@
}

function ConvertTo-HvEncodedCommand {
    # Pure: powershell.exe -EncodedCommand payload (Base64 of UTF-16LE).
    param([string]$Script)
    return [System.Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($Script))
}

# ---------------------------------------------------------------- shortcuts

function Install-HvShortcuts {
    # Desktop + Start menu shortcuts "HomeVault 管理" -> windows\HomeVault管理.cmd (all users when elevated,
    # so they also appear for the signed-in user when install was elevated with another administrator account).
    Assert-HvWindows 'shortcuts'
    $root = Get-HvRoot
    $target = Join-HvPath (Join-HvPath $root 'windows') $script:HvManageCmdName
    if (-not [System.IO.File]::Exists($target)) { Stop-Hv ('找不到 ' + $target + '：仓库不完整。') }
    if (Test-HvAdmin) {
        $desk = [System.Environment]::GetFolderPath('CommonDesktopDirectory')
        $prog = [System.Environment]::GetFolderPath('CommonPrograms')
    } else {
        $desk = [System.Environment]::GetFolderPath('Desktop')
        $prog = [System.Environment]::GetFolderPath('Programs')
    }
    $icon = [System.Environment]::ExpandEnvironmentVariables('%SystemRoot%\System32\shell32.dll') + ',8'
    $made = @()
    $shell = New-Object -ComObject WScript.Shell
    try {
        foreach ($it in @(Get-HvShortcutPlan -Root $root -DesktopDir $desk -ProgramsDir $prog -IconLocation $icon)) {
            try {
                [void](New-HvDirectory ([System.IO.Path]::GetDirectoryName($it.Path)))
                $lnk = $shell.CreateShortcut($it.Path)
                $lnk.TargetPath = $it.Target
                $lnk.WorkingDirectory = $it.WorkingDirectory
                $lnk.Description = $it.Description
                $lnk.IconLocation = $it.IconLocation
                $lnk.WindowStyle = 1
                $lnk.Save()
                $made += $it.Path
            } catch { Write-HvWarn ('无法创建快捷方式 ' + $it.Path + '：' + $_.Exception.Message) }
        }
    } finally {
        [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($shell)
    }
    if ($made.Count -gt 0) { Write-HvOk ('已创建快捷方式“' + $script:HvShortcutName + '”（桌面和开始菜单），以后双击它即可打开管理菜单。') }
    return $made
}

# ---------------------------------------------------------------- scheduled tasks

function Test-HvHeadlessSupported {
    if (-not (Test-HvWindows)) { return $false }
    $conhost = Join-HvPath ([System.Environment]::GetEnvironmentVariable('SystemRoot')) 'System32\conhost.exe'
    return ([System.Environment]::OSVersion.Version.Build -ge 19041 -and [System.IO.File]::Exists($conhost))
}

function New-HvUserTaskAction {
    param([string[]]$HvArgs, [bool]$Headless)
    $hv = Join-HvPath (Join-HvPath (Get-HvRoot) 'windows') 'hv.ps1'
    $a = Get-HvHiddenTaskAction -SystemRoot ([System.Environment]::GetEnvironmentVariable('SystemRoot')) -HvScript $hv -HvArgs $HvArgs -Headless $Headless
    return (New-ScheduledTaskAction -Execute $a.Execute -Argument $a.Argument -WorkingDirectory (Get-HvRoot))
}

function Register-HvUserTask {
    # Task as the signed-in desktop user (Docker Desktop is per-user), only while that user is logged on.
    param([string]$Name, [string[]]$HvArgs, $Trigger, [TimeSpan]$TimeLimit, [string]$Description, [bool]$Headless)
    $user = Get-HvDesktopUserName
    $principal = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Limited
    $settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
        -ExecutionTimeLimit $TimeLimit -MultipleInstances IgnoreNew
    [void](Register-ScheduledTask -TaskName $Name -Action (New-HvUserTaskAction -HvArgs $HvArgs -Headless $Headless) -Trigger $Trigger `
            -Principal $principal -Settings $settings -Description $Description -Force)
    return $user
}

function Get-HvRequestsLastRun {
    $s = Read-HvStateJson 'status.json'
    return [string](Get-HvPropValue (Get-HvPropValue $s 'requests') 'last_run' '')
}

function Test-HvRequestsTaskRuns {
    # Start the task once and wait until it has written state\status.json (requests.last_run changes).
    param([int]$TimeoutSec = 45)
    $before = Get-HvRequestsLastRun
    try { Start-ScheduledTask -TaskName $script:HvRequestsTask -ErrorAction Stop } catch { return $false }
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Seconds 2
        $now = Get-HvRequestsLastRun
        if ($now -and $now -ne $before) { return $true }
    }
    return $false
}

function Register-HvRequestsTask {
    # HomeVault-Requests: `hv.ps1 requests process` every 2 minutes as the desktop user, hidden. Verified by running it
    # once (falls back from conhost --headless to a plain hidden PowerShell if needed). With VPN enabled it also
    # registers the SYSTEM task HomeVault-VpnStatus.
    Assert-HvAdmin '注册计划任务 HomeVault-Requests'
    [void](Get-HvEnv)
    try { if (Get-Command Initialize-HvRuntimeDirs -ErrorAction SilentlyContinue) { Initialize-HvRuntimeDirs } } catch { }
    [void](New-HvDirectory (Join-HvPath (Join-HvPath (Get-HvStateDir) 'requests') 'done'))
    $trigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) -RepetitionInterval (New-TimeSpan -Minutes 2)
    $desc = 'HomeVault：每 2 分钟执行管理面板提交的请求（立即备份、清理日志、日志保留天数），并更新 state\status.json。'
    $modes = @($false)
    if (Test-HvHeadlessSupported) { $modes = @($true, $false) }
    $ok = $false
    $user = ''
    foreach ($headless in $modes) {
        $user = Register-HvUserTask -Name $script:HvRequestsTask -HvArgs @('requests', 'process', '--non-interactive') -Trigger $trigger `
            -TimeLimit (New-TimeSpan -Hours 23) -Description $desc -Headless $headless
        $script:HvTaskHeadless = $headless
        if (Test-HvRequestsTaskRuns) { $ok = $true; break }
    }
    if ($ok) { Write-HvOk ('已创建计划任务 ' + $script:HvRequestsTask + '：每 2 分钟以用户 ' + $user + ' 运行（后台，无窗口）。') }
    else { Write-HvWarn ('计划任务 ' + $script:HvRequestsTask + ' 已创建，但试运行没有成功：请打开“任务计划程序”查看该任务的“上次运行结果”。管理面板里的“立即备份/清理日志”需要它。') }
    # a maintenance task registered earlier in headless mode follows the launch mode that was verified here
    if (-not $script:HvTaskHeadless -and $modes.Count -gt 1) {
        $mt = $null
        try { $mt = Get-ScheduledTask -TaskName $script:HvMaintenanceTask -ErrorAction Stop } catch { }
        if ($null -ne $mt -and @($mt.Actions | Where-Object { [string]$_.Execute -like '*conhost.exe' }).Count -gt 0) {
            $at = '04:00'
            try { $at = ([datetime]$mt.Triggers[0].StartBoundary).ToString('HH:mm') } catch { }
            try { Register-HvMaintenanceTask -Time $at } catch { Write-HvWarn ('更新 ' + $script:HvMaintenanceTask + ' 失败：' + (Get-HvErrorMessage $_)) }
        }
    }
    if (Test-HvTrue (Get-HvEnvValue 'HV_VPN_ENABLED' 'true')) {
        try { Register-HvVpnStatusTask } catch { Write-HvWarn ('注册 ' + $script:HvVpnStatusTask + ' 失败：' + (Get-HvErrorMessage $_)) }
    }
}

function Register-HvMaintenanceTask {
    # HomeVault-Maintenance: `hv.ps1 maintenance` daily (default 04:00) as the desktop user, hidden; runs later if missed.
    param([string]$Time = '04:00')
    Assert-HvAdmin '注册计划任务 HomeVault-Maintenance'
    $at = ConvertTo-HvTaskTime $Time
    $headless = $script:HvTaskHeadless
    if ($null -eq $headless) { $headless = Test-HvHeadlessSupported }
    $user = Register-HvUserTask -Name $script:HvMaintenanceTask -HvArgs @('maintenance', '--non-interactive') `
        -Trigger (New-ScheduledTaskTrigger -Daily -At $at) -TimeLimit (New-TimeSpan -Hours 2) -Headless ([bool]$headless) `
        -Description ('HomeVault：每日维护（导出容器日志、按日期轮转 Nextcloud 日志、删除超过保留天数的日志、更新状态文件）。日志：' + (Get-HvLogDir))
    Write-HvOk ('已创建计划任务 ' + $script:HvMaintenanceTask + '：每天 ' + $at.ToString('HH:mm') + ' 以用户 ' + $user + ' 运行（错过时开机后补做）。')
}

function Register-HvVpnStatusTask {
    # HomeVault-VpnStatus: SYSTEM (session 0, no window), at startup + every 2 minutes. Needed because `wg show`
    # requires administrator rights, while the other tasks run as the (possibly standard) desktop user.
    Assert-HvAdmin '注册计划任务 HomeVault-VpnStatus'
    $ps = Join-HvPath ([System.Environment]::GetEnvironmentVariable('SystemRoot')) 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $arg = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -EncodedCommand ' + (ConvertTo-HvEncodedCommand (Get-HvVpnStatusScript))
    $action = New-ScheduledTaskAction -Execute $ps -Argument $arg
    $t1 = New-ScheduledTaskTrigger -AtStartup
    $t2 = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) -RepetitionInterval (New-TimeSpan -Minutes 2)
    $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable `
        -ExecutionTimeLimit (New-TimeSpan -Minutes 2) -MultipleInstances IgnoreNew
    [void](Register-ScheduledTask -TaskName $script:HvVpnStatusTask -Action $action -Trigger @($t1, $t2) -Principal $principal -Settings $settings `
            -Description 'HomeVault：每 2 分钟记录 VPN 设备的最近握手与流量（不含任何密钥），供管理面板显示。' -Force)
    try { Start-ScheduledTask -TaskName $script:HvVpnStatusTask -ErrorAction Stop } catch { }
    Write-HvOk ('已创建计划任务 ' + $script:HvVpnStatusTask + '（SYSTEM，每 2 分钟）。')
}

function Unregister-HvUxTasks {
    # Remove the tasks created here (uninstall).
    foreach ($n in @($script:HvRequestsTask, $script:HvMaintenanceTask, $script:HvVpnStatusTask)) {
        Unregister-ScheduledTask -TaskName $n -Confirm:$false -ErrorAction SilentlyContinue
    }
}
