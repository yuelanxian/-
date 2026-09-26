# HomeVault Windows CLI - Android app (SPEC section 16): `hv.ps1 android fetch` downloads the latest release APK
# (GitHub HV_ANDROID_RELEASE_REPO, asset homevault-android.apk + .sha256), verifies it and saves state\app\homevault.apk,
# which the management panel serves to phones at /download/android.

$script:HvAndroidDefaultRepo = 'yuelanxian/-'
$script:HvAndroidAsset = 'homevault-android.apk'

# ---------------------------------------------------------------- pure helpers

function Get-HvAndroidReleaseUrls {
    # Pure: "latest release" download URLs of the APK and its checksum for GitHub repository "owner/name".
    param([AllowEmptyString()][string]$Repo)
    $r = ([string]$Repo).Trim().Trim('/')
    if ($r -notmatch '^[A-Za-z0-9](?:[A-Za-z0-9-]{0,38})/[A-Za-z0-9._-]{1,100}$' -or $r -match '/\.{1,2}$') {
        throw ('HV_ANDROID_RELEASE_REPO 格式应为 “所有者/仓库名”（例如 ' + $script:HvAndroidDefaultRepo + '）：' + $Repo)
    }
    $base = 'https://github.com/' + $r + '/releases/latest/download/'
    return [pscustomobject]@{ Apk = ($base + $script:HvAndroidAsset); Sha256 = ($base + $script:HvAndroidAsset + '.sha256') }
}

function ConvertFrom-HvSha256Text {
    # Pure: the SHA-256 hex digest in a checksum file ("<hex>", "<hex>  file.apk", "SHA256 (file) = <hex>"); '' if none.
    param([AllowEmptyString()][AllowNull()][string]$Text)
    $m = [regex]::Match([string]$Text, '(?<![0-9A-Fa-f])[0-9A-Fa-f]{64}(?![0-9A-Fa-f])')
    if ($m.Success) { return $m.Value.ToLowerInvariant() }
    return ''
}

function Test-HvApkFile {
    # An APK is a ZIP file: it starts with "PK\x03\x04".
    param([string]$Path)
    if (-not [System.IO.File]::Exists($Path)) { return $false }
    $fs = [System.IO.File]::OpenRead($Path)
    try {
        $b = New-Object byte[] 4
        $n = $fs.Read($b, 0, 4)
        return ($n -eq 4 -and $b[0] -eq 0x50 -and $b[1] -eq 0x4B -and $b[2] -eq 0x03 -and $b[3] -eq 0x04)
    } finally { $fs.Dispose() }
}

# ---------------------------------------------------------------- download

function Invoke-HvDownloadFile {
    # HTTPS download to a file (TLS 1.2 on Windows PowerShell 5.1; no progress bar - it makes 5.1 very slow).
    param([string]$Url, [string]$OutFile, [int]$TimeoutSec = 900)
    if ($Url -notmatch '^https://') { Stop-Hv ('只允许 https:// 下载地址：' + $Url) 2 }
    try { [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor [System.Net.SecurityProtocolType]::Tls12 } catch { }
    $ProgressPreference = 'SilentlyContinue'
    Invoke-WebRequest -Uri $Url -OutFile $OutFile -UseBasicParsing -TimeoutSec $TimeoutSec -MaximumRedirection 10 -ErrorAction Stop
}

function Invoke-HvAndroidFetch {
    # -File: use a local APK (e.g. downloaded manually); -Url: another download address (checksum at <url>.sha256
    # unless -Sha256 is given). The APK is verified (SHA-256, ZIP header) before it replaces state\app\homevault.apk.
    param([string]$Url = '', [string]$File = '', [string]$Sha256 = '')
    $appDir = New-HvDirectory (Join-HvPath (Get-HvStateDir) 'app')
    $dest = Join-HvPath $appDir 'homevault.apk'
    $tmp = New-HvTempPath $dest
    $want = ''
    if ($Sha256) {
        $want = ConvertFrom-HvSha256Text $Sha256
        if (-not $want) { Stop-Hv '--sha256 应为 64 位十六进制的 SHA-256 值。' 2 }
    }
    try {
        if ($File) {
            if (-not [System.IO.File]::Exists($File)) { Stop-Hv ('找不到文件：' + $File) 2 }
            Write-HvStep ('使用本地安装包：' + $File)
            Copy-Item -LiteralPath $File -Destination $tmp -Force
        } else {
            $shaUrl = ''
            if ($Url) { $shaUrl = $Url + '.sha256' }
            else {
                try { $u = Get-HvAndroidReleaseUrls (Get-HvEnvValue 'HV_ANDROID_RELEASE_REPO' $script:HvAndroidDefaultRepo) } catch { Stop-Hv $_.Exception.Message 2 }
                $Url = $u.Apk
                $shaUrl = $u.Sha256
            }
            if (-not $want) {
                $shaTmp = $tmp + '.sha256'
                try {
                    Write-HvInfo ('下载校验值：' + $shaUrl)
                    Invoke-HvDownloadFile -Url $shaUrl -OutFile $shaTmp -TimeoutSec 60
                    $want = ConvertFrom-HvSha256Text (Read-HvTextFile $shaTmp)
                } catch {
                    Stop-Hv ('无法下载校验文件（' + $_.Exception.Message + '）。可在电脑上手动下载 APK 后运行：android fetch --file <APK 路径> [--sha256 <校验值>]')
                } finally {
                    Remove-Item -LiteralPath $shaTmp -Force -ErrorAction SilentlyContinue
                }
                if (-not $want) { Stop-Hv ('校验文件中没有 SHA-256 值：' + $shaUrl) }
            }
            Write-HvStep ('下载安卓 App：' + $Url)
            try { Invoke-HvDownloadFile -Url $Url -OutFile $tmp } catch {
                Stop-Hv ('下载失败（' + $_.Exception.Message + '）。国内访问 GitHub 可能较慢：可稍后重试，或手动下载后用 android fetch --file <APK 路径>。')
            }
        }
        $hash = (Get-FileHash -LiteralPath $tmp -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($want -and $hash -ne $want) { Stop-Hv ('SHA-256 校验失败：期望 ' + $want + '，实际 ' + $hash + '（文件可能不完整或被篡改），已丢弃。') }
        if (-not (Test-HvApkFile $tmp)) { Stop-Hv '文件不是有效的 APK 安装包（ZIP 格式），已丢弃。' }
        Move-HvFileReplace -Source $tmp -Destination $dest
        Write-HvJsonFile -Path ($dest + '.sha256') -Value ($hash + '  homevault.apk' + "`n") -Raw
        $size = (New-Object System.IO.FileInfo($dest)).Length
        Write-HvOk ('已保存：' + $dest + '（' + (ConvertTo-HvSizeText $size) + '）')
        Write-HvInfo ('SHA-256：' + $hash)
        if (-not $want) { Write-HvWarn '未提供校验值（--sha256），请自行核对上面的 SHA-256 与发布页一致。' }
        Write-HvInfo '手机打开管理面板 → 设置 → 安卓 App，扫码即可下载安装。'
        return $dest
    } finally {
        if ([System.IO.File]::Exists($tmp)) { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
    }
}

function Show-HvAndroidStatus {
    $f = Join-HvPath (Join-HvPath (Get-HvStateDir) 'app') 'homevault.apk'
    if (-not [System.IO.File]::Exists($f)) {
        Write-HvInfo '还没有下载安卓 App：运行 .\windows\hv.ps1 android fetch'
        return
    }
    $fi = New-Object System.IO.FileInfo($f)
    Write-HvOk ('安卓 App：' + $f + '（' + (ConvertTo-HvSizeText $fi.Length) + '，' + $fi.LastWriteTime.ToString('yyyy-MM-dd HH:mm', [System.Globalization.CultureInfo]::InvariantCulture) + '）')
    Write-HvInfo ('SHA-256：' + (Get-FileHash -LiteralPath $f -Algorithm SHA256).Hash.ToLowerInvariant())
}

function Invoke-HvAndroid {
    # hv.ps1 android fetch [--url <APK 地址>] [--file <本地 APK>] [--sha256 <校验值>] | android status
    param([Parameter(ValueFromRemainingArguments = $true)][object[]]$Arguments = @())
    $p = Read-HvCommandArgs -Arguments $Arguments -Options @('url', 'file', 'sha256')
    $sub = 'fetch'
    if ($p.Positional.Count -gt 0) { $sub = $p.Positional[0].ToLowerInvariant() }
    [void](Get-HvEnv)
    switch ($sub) {
        'fetch' {
            Start-HvUxLog 'android fetch'
            [void](Invoke-HvAndroidFetch -Url (Get-HvOpt $p 'url' '') -File (Get-HvOpt $p 'file' '') -Sha256 (Get-HvOpt $p 'sha256' ''))
        }
        'status' { Show-HvAndroidStatus }
        default { Stop-Hv '用法：android fetch [--url <APK 下载地址>] [--file <本地 APK>] [--sha256 <校验值>] | android status' 2 }
    }
}
