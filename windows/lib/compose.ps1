# HomeVault Windows CLI - docker compose wrappers, preflight and health waiting.

function Get-HvComposeFileList {
    # Pure: compose files in merge order.
    param([string]$Root, [string]$TlsMode, [bool]$StorageFileExists, [string[]]$ExtraFiles = @())
    $files = @((Join-HvPath $Root 'compose.yaml'))
    if ($TlsMode -eq 'acme-dns') { $files += (Join-HvPath $Root 'compose.acme.yaml') }
    if ($StorageFileExists) { $files += (Join-HvPath $Root 'compose.storage.yaml') }
    foreach ($f in @($ExtraFiles)) { if ($f) { $files += $f } }
    return $files
}

function Get-HvComposeProfiles {
    # Pure: profiles for Windows (never vpn/monitor: wg-easy and scrutiny are Linux only).
    param([System.Collections.IDictionary]$Env, [switch]$Tools)
    $p = @()
    if (Test-HvTrue (Get-HvEnvDictValue $Env 'HV_DDNS_ENABLED' 'false')) { $p += 'ddns' }
    if ($Tools) { $p += 'tools' }
    return $p
}

function Set-HvComposeProcessEnv {
    # compose.yaml passes HV_VERSION to the panel from the process environment (not from .env).
    if ($script:HvVersion) { $env:HV_VERSION = [string]$script:HvVersion }
}

function Get-HvComposeArgs {
    param([switch]$Tools, [string[]]$ExtraFiles = @())
    Set-HvComposeProcessEnv
    $root = Get-HvRoot
    $envv = Get-HvEnv
    $files = Get-HvComposeFileList -Root $root -TlsMode (Get-HvEnvDictValue $envv 'HV_TLS_MODE' 'internal') `
        -StorageFileExists ([System.IO.File]::Exists((Join-HvPath $root 'compose.storage.yaml'))) -ExtraFiles $ExtraFiles
    $a = @('compose')
    foreach ($f in $files) { $a += @('-f', $f) }
    $a += @('--env-file', (Get-HvEnvPath))
    foreach ($p in (Get-HvComposeProfiles -Env $envv -Tools:$Tools)) { $a += @('--profile', $p) }
    return $a
}

function Invoke-HvCompose {
    param(
        [string[]]$Arguments = @(),
        [switch]$Capture,
        [switch]$Quiet,
        [switch]$Tee,
        [switch]$AllowFailure,
        [switch]$Tools,
        [string[]]$ExtraFiles = @(),
        [AllowNull()]$InputText = $null
    )
    $a = @(Get-HvComposeArgs -Tools:$Tools -ExtraFiles $ExtraFiles) + @($Arguments)
    return (Invoke-HvNative -FilePath 'docker' -ArgumentList $a -Capture:$Capture -Quiet:$Quiet -Tee:$Tee -AllowFailure:$AllowFailure -InputText $InputText)
}

function Get-HvComposePs {
    # Container rows of this project (running and stopped).
    $r = Invoke-HvCompose -Arguments @('ps', '-a', '--format', 'json') -Capture -AllowFailure
    if ($r.ExitCode -ne 0) { return @() }
    return @(ConvertFrom-HvJsonArrayText $r.Text)
}

function Get-HvServiceState {
    param([object[]]$Rows, [string]$Service)
    foreach ($r in @($Rows)) {
        if ((Get-HvPropValue $r 'Service') -eq $Service) {
            return [pscustomobject]@{ State = [string](Get-HvPropValue $r 'State'); Health = [string](Get-HvPropValue $r 'Health'); Status = [string](Get-HvPropValue $r 'Status') }
        }
    }
    return $null
}

function Test-HvAppRunning {
    $s = Get-HvServiceState -Rows (Get-HvComposePs) -Service 'app'
    return ($null -ne $s -and $s.State -eq 'running')
}

function Invoke-HvOcc {
    # docker compose exec -T -u www-data app php occ ...; -PassEnv names are taken from this process' environment.
    param([string[]]$OccArgs, [switch]$Capture, [switch]$AllowFailure, [switch]$Quiet, [string[]]$PassEnv = @(), [switch]$Tty)
    $a = @('exec')
    if (-not $Tty) { $a += '-T' }
    $a += @('-u', 'www-data')
    foreach ($e in @($PassEnv)) { $a += @('-e', $e) }
    $a += @('app', 'php', 'occ') + @($OccArgs)
    return (Invoke-HvCompose -Arguments $a -Capture:$Capture -AllowFailure:$AllowFailure -Quiet:$Quiet)
}

function Get-HvOccJson {
    param([string[]]$OccArgs)
    $r = Invoke-HvOcc -OccArgs $OccArgs -Capture -AllowFailure
    if ($r.ExitCode -ne 0) { return $null }
    $slice = Get-HvJsonSlice $r.Text
    if (-not $slice) { return $null }
    try { return (ConvertFrom-Json -InputObject $slice) } catch { return $null }
}

function Get-HvOccStatus { return (Get-HvOccJson @('status', '--output=json')) }

function Get-HvOccValue {
    param([string[]]$OccArgs)
    $r = Invoke-HvOcc -OccArgs $OccArgs -Capture -AllowFailure
    if ($r.ExitCode -ne 0) { return $null }
    return ($r.Text.Trim())
}

# ---------------------------------------------------------------- preflight

function Get-HvDockerInfo {
    $r = Invoke-HvNative -FilePath 'docker' -ArgumentList @('version', '--format', '{{json .}}') -Capture -AllowFailure
    $info = [pscustomobject]@{ Ok = $false; ClientVersion = ''; ServerVersion = ''; Platform = ''; DesktopVersion = ''; OSType = ''; ComposeVersion = ''; Error = '' }
    if ($r.ExitCode -ne 0) { $info.Error = ($r.StdErr -join ' '); return $info }
    try {
        $j = ConvertFrom-Json -InputObject (Get-HvJsonSlice $r.Text)
        $info.ClientVersion = [string](Get-HvPropValue (Get-HvPropValue $j 'Client') 'Version')
        $srv = Get-HvPropValue $j 'Server'
        if ($null -eq $srv) { $info.Error = '无法连接 Docker 引擎'; return $info }
        $info.ServerVersion = [string](Get-HvPropValue $srv 'Version')
        $info.OSType = [string](Get-HvPropValue $srv 'Os')
        $info.Platform = [string](Get-HvPropValue (Get-HvPropValue $srv 'Platform') 'Name')
        $m = [regex]::Match($info.Platform, 'Docker Desktop\s+([0-9.]+)')
        if ($m.Success) { $info.DesktopVersion = $m.Groups[1].Value }
        $info.Ok = $true
    } catch { $info.Error = $_.Exception.Message }
    $c = Invoke-HvNative -FilePath 'docker' -ArgumentList @('compose', 'version', '--short') -Capture -AllowFailure
    if ($c.ExitCode -eq 0) { $info.ComposeVersion = $c.Text.Trim().TrimStart('v') }
    return $info
}

function Add-HvDockerCliToPath {
    # A fresh Docker Desktop install is not yet on this session's PATH.
    if (-not (Test-HvWindows)) { return }
    if (Get-Command docker -ErrorAction SilentlyContinue) { return }
    $pf = [System.Environment]::GetEnvironmentVariable('ProgramFiles')
    if (-not $pf) { return }
    $bin = Join-HvPath $pf 'Docker\Docker\resources\bin'
    if ([System.IO.File]::Exists((Join-HvPath $bin 'docker.exe'))) { $env:PATH = $env:PATH + ';' + $bin }
}

function Install-HvDockerDesktop {
    # Offer `winget install Docker.DockerDesktop` (after confirmation). Always stops: a reboot/sign-in is needed afterwards.
    $manual = '请先安装 Docker Desktop（https://www.docker.com/products/docker-desktop/ ，版本 ≥ 4.92），安装后启动一次并完成首次设置，看到 Engine running 后重新运行安装。'
    if (-not (Test-HvWindows) -or -not (Get-Command winget -ErrorAction SilentlyContinue)) { Stop-Hv ('未找到 docker 命令：' + $manual) }
    Write-HvWarn '未检测到 Docker Desktop（HomeVault 的全部服务运行在 Docker 容器中）。'
    if (-not (Read-HvYesNo '现在用 winget 安装 Docker Desktop（Docker.DockerDesktop，约 600 MB）？' $true)) { Stop-Hv ('已取消。' + $manual) }
    $r = Invoke-HvNative -FilePath 'winget' -ArgumentList @('install', '-e', '--id', 'Docker.DockerDesktop', '--accept-package-agreements', '--accept-source-agreements') -AllowFailure
    if ($r.ExitCode -ne 0) { Stop-Hv ('winget 安装 Docker Desktop 失败（退出码 ' + $r.ExitCode + '）。' + $manual) }
    Stop-Hv ('Docker Desktop 已安装。请重启电脑（或注销后重新登录），打开 Docker Desktop 完成首次设置（接受协议，登录可跳过），' +
        '看到左下角 Engine running 后，再次运行安装（双击“一键安装”或 .\windows\hv.ps1 install）。') 3
}

function Start-HvDockerDesktop {
    # Start Docker Desktop if it is installed but not running; waits for the engine. Returns $true when it answers.
    param([int]$TimeoutSec = 300)
    if (-not (Test-HvWindows)) { return $false }
    $exe = Get-HvDockerDesktopExe
    if (-not $exe) { return $false }
    Write-HvInfo '正在启动 Docker Desktop，请稍候（首次启动可能需要几分钟）...'
    try { Start-Process -FilePath $exe } catch { return $false }
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Seconds 5
        if ((Get-HvDockerInfo).Ok) { return $true }
    }
    return $false
}

function Assert-HvDocker {
    # Docker Desktop running, Linux containers, Compose >= 2.24. -OfferInstall: offer winget install when missing.
    param([switch]$OfferInstall)
    Add-HvDockerCliToPath
    if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
        if ($OfferInstall) { Install-HvDockerDesktop }
        Stop-Hv '未找到 docker 命令：请先安装 Docker Desktop（https://www.docker.com/products/docker-desktop/，版本 ≥ 4.92），安装后启动一次并完成登录向导。'
    }
    $i = Get-HvDockerInfo
    if (-not $i.Ok -and (Start-HvDockerDesktop)) { $i = Get-HvDockerInfo }
    if (-not $i.Ok) { Stop-Hv ('Docker 引擎不可用：请先启动 Docker Desktop，等待左下角显示 Engine running 后重试。（' + $i.Error + '）') }
    if ($i.OSType -and $i.OSType -ne 'linux') { Stop-Hv 'Docker Desktop 当前处于 Windows 容器模式：请在托盘图标菜单中选择“Switch to Linux containers”。' }
    if (-not $i.ComposeVersion -or (Compare-HvVersion $i.ComposeVersion '2.24.0') -lt 0) {
        Stop-Hv ('Docker Compose 版本过低（' + $i.ComposeVersion + '），需要 ≥ 2.24：请升级 Docker Desktop。')
    }
    return $i
}

function Wait-HvHealthy {
    # Wait until app is running/healthy and Nextcloud reports installed=true.
    param([int]$TimeoutSec = 900)
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    $lastMsg = ''
    Write-HvInfo '等待服务就绪（首次安装可能需要几分钟）...'
    while ((Get-Date) -lt $deadline) {
        $rows = Get-HvComposePs
        $app = Get-HvServiceState -Rows $rows -Service 'app'
        $db = Get-HvServiceState -Rows $rows -Service 'db'
        $msg = ''
        if ($null -eq $app) { $msg = 'app 容器尚未创建' }
        elseif ($app.State -eq 'exited' -or $app.State -eq 'dead') {
            Invoke-HvCompose -Arguments @('logs', '--tail', '60', 'app') -AllowFailure | Out-Null
            Stop-Hv 'app 容器已退出，请查看上面的日志（.\windows\hv.ps1 logs app）。'
        }
        elseif ($app.State -ne 'running') { $msg = 'app 状态：' + $app.State }
        elseif ($db -and $db.Health -and $db.Health -ne 'healthy') { $msg = '数据库状态：' + $db.Health }
        elseif ($app.Health -and $app.Health -ne 'healthy') { $msg = 'app 健康检查：' + $app.Health }
        else {
            $st = Get-HvOccStatus
            if ($null -ne $st -and (Test-HvTrue (Get-HvPropValue $st 'installed')) -and -not (Test-HvTrue (Get-HvPropValue $st 'needsDbUpgrade'))) {
                Write-HvOk ('Nextcloud 已就绪（版本 ' + [string](Get-HvPropValue $st 'versionstring') + '）')
                return $true
            }
            $msg = 'Nextcloud 正在初始化'
        }
        if ($msg -ne $lastMsg) { Write-HvInfo $msg; $lastMsg = $msg }
        Start-Sleep -Seconds 5
    }
    Stop-Hv ('等待服务就绪超时（' + $TimeoutSec + ' 秒）：请运行 .\windows\hv.ps1 logs app 查看原因。')
}
