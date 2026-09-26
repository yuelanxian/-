# HomeVault Windows CLI - .env reading/writing (comments and order preserved) and derived variables.

$script:HvEnvCache = $null

function Get-HvEnvKeyFromLine {
    param([AllowEmptyString()][string]$Line)
    if ($Line -match '^\s*(?:export\s+)?([A-Za-z_][A-Za-z0-9_]*)\s*=') { return $Matches[1] }
    return $null
}

function ConvertFrom-HvEnvRawValue {
    # Same rules as docker compose's dotenv parser for the cases we write:
    # 'single' = literal, "double" = basic escapes, unquoted = strip " #comment" and trim.
    param([AllowEmptyString()][string]$Raw)
    $v = $Raw.Trim()
    if ($v.Length -ge 1 -and $v[0] -eq [char]39) {
        $end = $v.IndexOf([char]39, 1)
        if ($end -gt 0) { return $v.Substring(1, $end - 1) }
        return $v.Substring(1)
    }
    if ($v.Length -ge 1 -and $v[0] -eq [char]34) {
        $sb = New-Object System.Text.StringBuilder
        $i = 1
        while ($i -lt $v.Length) {
            $ch = $v[$i]
            if ($ch -eq [char]92 -and ($i + 1) -lt $v.Length) {
                $nx = $v[$i + 1]
                if ($nx -eq 'n') { [void]$sb.Append("`n") }
                elseif ($nx -eq 't') { [void]$sb.Append("`t") }
                elseif ($nx -eq [char]34 -or $nx -eq [char]92) { [void]$sb.Append($nx) }
                else { [void]$sb.Append($ch); [void]$sb.Append($nx) }
                $i += 2
                continue
            }
            if ($ch -eq [char]34) { break }
            [void]$sb.Append($ch)
            $i++
        }
        return $sb.ToString()
    }
    $v = [regex]::Replace($v, '\s+#.*$', '')
    return $v.Trim()
}

function ConvertFrom-HvEnvText {
    param([AllowEmptyString()][string]$Text)
    $result = [ordered]@{}
    foreach ($line in ($Text -split "`r?`n")) {
        $k = Get-HvEnvKeyFromLine $line
        if ($null -eq $k) { continue }
        $raw = $line.Substring($line.IndexOf('=') + 1)
        $result[$k] = ConvertFrom-HvEnvRawValue $raw
    }
    return $result
}

function Format-HvEnvValue {
    # Unquoted when safe; single quotes (literal, no ${} interpolation) otherwise.
    param([AllowEmptyString()][AllowNull()][string]$Value)
    if ($null -eq $Value) { return '' }
    if ($Value -match "[`r`n]") { throw '.env 的值不能包含换行符。' }
    if (($Value -match '[\$#"''`]') -or ($Value -ne $Value.Trim())) {
        if ($Value.IndexOf([char]39) -ge 0) { throw ('.env 的值不能同时包含单引号和特殊字符：' + $Value) }
        return ("'" + $Value + "'")
    }
    return $Value
}

function Split-HvLines {
    # Lines without the trailing empty element produced by a final newline.
    param([AllowEmptyString()][string]$Text)
    $lines = @($Text -split "`r?`n")
    if ($lines.Count -gt 0 -and $lines[$lines.Count - 1] -eq '') {
        if ($lines.Count -eq 1) { return @() }
        $lines = $lines[0..($lines.Count - 2)]
    }
    return $lines
}

function Set-HvEnvLines {
    # Update existing KEY= lines in place, drop later duplicates, append missing keys at the end.
    param([AllowEmptyCollection()][string[]]$Lines = @(), [System.Collections.IDictionary]$Values)
    $out = New-Object System.Collections.Generic.List[string]
    $done = New-Object 'System.Collections.Generic.HashSet[string]'
    foreach ($line in @($Lines)) {
        $k = Get-HvEnvKeyFromLine $line
        if ($null -ne $k -and $Values.Contains($k)) {
            if ($done.Contains($k)) { continue }
            $out.Add($k + '=' + (Format-HvEnvValue ([string]$Values[$k])))
            [void]$done.Add($k)
        } else {
            $out.Add([string]$line)
        }
    }
    $missing = @()
    foreach ($k in $Values.Keys) { if (-not $done.Contains([string]$k)) { $missing += [string]$k } }
    if ($missing.Count -gt 0) {
        $hasMarker = $false
        foreach ($l in $out) { if ($l -like '# ---- hv.ps1*') { $hasMarker = $true } }
        if (-not $hasMarker) {
            if ($out.Count -gt 0 -and $out[$out.Count - 1].Trim() -ne '') { $out.Add('') }
            $out.Add('# ---- hv.ps1 追加的变量（.env.example 中没有的项）----')
        }
        foreach ($k in $missing) { $out.Add($k + '=' + (Format-HvEnvValue ([string]$Values[$k]))) }
    }
    return $out.ToArray()
}

function Read-HvEnvFile {
    param([Parameter(Mandatory = $true)][string]$Path)
    $text = Read-HvTextFile $Path
    return @{ Lines = @(Split-HvLines $text); Values = (ConvertFrom-HvEnvText $text) }
}

function Save-HvEnvLines {
    param([Parameter(Mandatory = $true)][string]$Path, [AllowEmptyCollection()][string[]]$Lines)
    Write-HvTextFile -Path $Path -Content ((@($Lines) -join "`n") + "`n")
}

function Get-HvEnvPath { return (Get-HvPath '.env') }

function Test-HvEnvExists { return [System.IO.File]::Exists((Get-HvEnvPath)) }

function Get-HvEnv {
    # Load (cached) .env values; fails with a helpful message if HomeVault is not installed.
    param([switch]$Reload)
    if ($script:HvEnvCache -and -not $Reload) { return $script:HvEnvCache }
    $p = Get-HvEnvPath
    if (-not [System.IO.File]::Exists($p)) { Stop-Hv ('未找到 ' + $p + '：请先运行 .\windows\hv.ps1 install') }
    $script:HvEnvCache = (Read-HvEnvFile $p).Values
    return $script:HvEnvCache
}

function Get-HvEnvValue {
    param([string]$Name, [string]$Default = '')
    $e = Get-HvEnv
    if ($e.Contains($Name)) {
        $v = [string]$e[$Name]
        if ($v -ne '') { return $v }
    }
    return $Default
}

function Update-HvEnv {
    # Write the given values into .env (creating it from .env.example when missing).
    param([System.Collections.IDictionary]$Values)
    $p = Get-HvEnvPath
    if ([System.IO.File]::Exists($p)) {
        $lines = (Read-HvEnvFile $p).Lines
    } else {
        $ex = Get-HvPath '.env.example'
        if (-not [System.IO.File]::Exists($ex)) { Stop-Hv ('缺少 ' + $ex + '，仓库不完整。') }
        $lines = @(Split-HvLines (Read-HvTextFile $ex))
    }
    $new = @(Set-HvEnvLines -Lines $lines -Values $Values)
    Save-HvEnvLines -Path $p -Lines $new
    Set-HvPrivateAcl -Path $p
    $script:HvEnvCache = $null
    [void](Get-HvEnv -Reload)
}

# ---------------------------------------------------------------- derived values

function Get-HvWinWgDir {
    $pd = [System.Environment]::GetEnvironmentVariable('ProgramData')
    if (-not $pd) { return '' }
    return (Join-HvPath $pd 'HomeVault\wireguard')
}

function Get-HvEnvDictValue {
    param([System.Collections.IDictionary]$Env, [string]$Name, [string]$Default = '')
    if ($Env.Contains($Name)) {
        $v = [string]$Env[$Name]
        if ($v -ne '') { return $v }
    }
    return $Default
}

function Get-HvCanonicalHosts {
    # Every name/IP clients may use (order matters: the first one is the canonical URL).
    param([System.Collections.IDictionary]$Env, [string]$Platform = 'windows')
    $list = New-Object System.Collections.Generic.List[string]
    $add = {
        param($h)
        $h = ([string]$h).Trim()
        if ($h -ne '' -and -not $list.Contains($h)) { $list.Add($h) }
    }
    $hostName = Get-HvEnvDictValue $Env 'HV_HOST'
    $lan = Get-HvEnvDictValue $Env 'HV_LAN_IP'
    if (-not $hostName) { $hostName = $lan }
    & $add $hostName
    $tls = Get-HvEnvDictValue $Env 'HV_TLS_MODE' 'internal'
    if ($tls -eq 'internal') {
        & $add $lan
        $vpnOn = Test-HvTrue (Get-HvEnvDictValue $Env 'HV_VPN_ENABLED' 'true')
        $cidr = Get-HvEnvDictValue $Env 'HV_VPN_CIDR'
        if ($Platform -eq 'windows' -and $vpnOn -and $cidr) { & $add (Get-HvVpnServerIp $cidr) }
    }
    foreach ($x in ((Get-HvEnvDictValue $Env 'HV_EXTRA_HOSTS') -split '[\s,]+')) { & $add $x }
    return $list.ToArray()
}

function Get-HvDerivedEnv {
    # Values recomputed on every install/up and written back to .env (SPEC section 5).
    param([System.Collections.IDictionary]$Env, [string]$Platform = 'windows', [string]$WinWgDir = '')
    $port = Get-HvEnvDictValue $Env 'HV_HTTPS_PORT' '443'
    $hosts = @(Get-HvCanonicalHosts -Env $Env -Platform $Platform)
    if ($hosts.Count -eq 0) { throw '缺少 HV_HOST / HV_LAN_IP，无法生成站点地址。' }
    $site = @(); $trusted = @()
    foreach ($h in $hosts) {
        $site += ('https://' + $h + ':' + $port)
        $trusted += $h
        if ($port -ne '443') { $trusted += ($h + ':' + $port) }
    }
    $overwrite = 'https://' + $hosts[0]
    if ($port -ne '443') { $overwrite += (':' + $port) }
    $tls = Get-HvEnvDictValue $Env 'HV_TLS_MODE' 'internal'
    $tlsSnippet = 'internal'
    if ($tls -eq 'acme-dns') { $tlsSnippet = 'acme-' + (Get-HvEnvDictValue $Env 'HV_DNS_PROVIDER' 'alidns') }
    $vpnOn = Test-HvTrue (Get-HvEnvDictValue $Env 'HV_VPN_ENABLED' 'true')
    $admin = 'none'
    if ($Platform -eq 'linux' -and $vpnOn) { $admin = 'wgeasy' }
    $d = [ordered]@{}
    $d['HV_PLATFORM'] = $Platform
    $d['HV_SITE_ADDRESSES'] = ($site -join ', ')
    $d['HV_TRUSTED_DOMAINS'] = ($trusted -join ' ')
    $d['HV_OVERWRITE_CLI_URL'] = $overwrite
    $d['HV_TLS_SNIPPET'] = $tlsSnippet
    $d['HV_ADMIN_SNIPPET'] = $admin
    if ($Platform -eq 'windows') {
        if ($vpnOn -and $WinWgDir) { $d['HV_WIN_WG_DIR'] = $WinWgDir } else { $d['HV_WIN_WG_DIR'] = '' }
    }
    return $d
}

function Update-HvDerivedEnv {
    # Recompute derived values and write them to .env if they changed.
    $envv = Get-HvEnv -Reload
    $wgDir = ''
    if (Test-HvTrue (Get-HvEnvDictValue $envv 'HV_VPN_ENABLED' 'true')) {
        $candidate = Get-HvWinWgDir
        if ($candidate -and [System.IO.Directory]::Exists($candidate)) { $wgDir = $candidate }
    }
    $d = Get-HvDerivedEnv -Env $envv -Platform 'windows' -WinWgDir $wgDir
    $changed = $false
    foreach ($k in $d.Keys) { if ((Get-HvEnvDictValue $envv $k) -ne [string]$d[$k]) { $changed = $true } }
    if ($changed) { Update-HvEnv $d }
}

# ---------------------------------------------------------------- image mirrors

$script:HvGhcrImageVars = @('WG_EASY_IMAGE', 'SCRUTINY_IMAGE')

function Get-HvMirrorPrefixes {
    param([string]$Preset, [string]$Hub = '', [string]$Ghcr = '')
    switch -regex ($Preset) {
        '^(?i)(none|off|default|docker)$' { return @{ Hub = 'docker.io'; Ghcr = 'ghcr.io'; GoProxy = 'https://proxy.golang.org,direct' } }
        '^(?i)daocloud$' { return @{ Hub = 'docker.m.daocloud.io'; Ghcr = 'ghcr.m.daocloud.io'; GoProxy = 'https://goproxy.cn,direct' } }
        '^(?i)custom$' {
            if (-not $Hub -or -not $Ghcr) { throw '--mirror custom 需要同时提供 Docker Hub 和 ghcr.io 的镜像前缀。' }
            return @{ Hub = $Hub.TrimEnd('/'); Ghcr = $Ghcr.TrimEnd('/'); GoProxy = 'https://goproxy.cn,direct' }
        }
    }
    throw ('未知的镜像源：' + $Preset + '（可选 daocloud / custom / none）')
}

function Get-HvMirroredImage {
    # Replace the registry host of a full image reference; the canonical registry is decided by variable name.
    param([string]$VarName, [string]$Image, [hashtable]$Prefixes)
    if (-not $Image) { return $Image }
    $rest = $Image
    $first = ($Image -split '/', 2)[0]
    if ($Image.Contains('/') -and ($first.Contains('.') -or $first.Contains(':') -or $first -eq 'localhost')) {
        $rest = ($Image -split '/', 2)[1]
    } elseif (-not $Image.Contains('/')) {
        $rest = 'library/' + $Image
    }
    if ($script:HvGhcrImageVars -contains $VarName) { return ($Prefixes.Ghcr + '/' + $rest) }
    if ($rest -like 'homevault/*') { return $Image }
    return ($Prefixes.Hub + '/' + $rest)
}

function Get-HvMirrorEnvChanges {
    param([System.Collections.IDictionary]$Env, [hashtable]$Prefixes)
    $d = [ordered]@{}
    foreach ($k in @($Env.Keys)) {
        if ([string]$k -match '_IMAGE$') {
            $v = [string]$Env[$k]
            if ($v) { $d[[string]$k] = Get-HvMirroredImage -VarName ([string]$k) -Image $v -Prefixes $Prefixes }
        }
    }
    $d['HV_GOPROXY'] = $Prefixes.GoProxy
    return $d
}
