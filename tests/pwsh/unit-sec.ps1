#Requires -Version 5.1
# Regression tests for the adversarial review of the Windows CLI (security / portability fixes):
#   - Windows PowerShell 5.1 native argument passing (emulated): quotes and trailing backslashes survive
#   - the management panel container cannot rewrite state\ (compose.storage.yaml mounts) or read the data folder
#   - host writes into panel-writable folders never follow planted links; the request runner refuses linked done\
#   - backup lock lets readers in (restic reads the project folder while the lock is held)
param(
    [string]$Root = (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)),
    [string]$OutDir = ''
)

$ErrorActionPreference = 'Stop'
$script:HvRoot = $Root
foreach ($lib in @(Get-ChildItem -LiteralPath (Join-Path $Root 'windows/lib') -Filter '*.ps1' | Sort-Object Name)) { . $lib.FullName }
if (-not $OutDir) { $OutDir = Join-Path ([System.IO.Path]::GetTempPath()) ('hv-sec-' + [guid]::NewGuid().ToString('N')) }
[void](New-Item -ItemType Directory -Force -Path $OutDir)

$script:Pass = 0
$script:Fail = 0
function Assert-Eq {
    param([string]$Name, $Expected, $Actual)
    $e = $Expected; $a = $Actual
    if ($e -is [System.Array]) { $e = '[' + ($e -join '|') + ']' }
    if ($a -is [System.Array]) { $a = '[' + ($a -join '|') + ']' }
    if ([string]$e -ceq [string]$a) { $script:Pass++ } else {
        $script:Fail++
        Write-Host ('  FAIL ' + $Name)
        Write-Host ('       expected: ' + [string]$e)
        Write-Host ('       actual:   ' + [string]$a)
    }
}
function Assert-True {
    param([string]$Name, $Cond)
    if ($Cond) { $script:Pass++ } else { $script:Fail++; Write-Host ('  FAIL ' + $Name) }
}
function Section { param([string]$T) Write-Host ('-- ' + $T) }

# ------------------------------------------------------------------ PS 5.1 native argument passing
Section 'Windows PowerShell 5.1 native arguments (emulated binder + MSVCRT/Go parser)'
function Test-Ps51NeedQuotes {
    # Windows PowerShell 5.1 NativeCommandParameterBinder.NeedQuotes; -BackslashAware = the PowerShell 6.x variant.
    param([string]$Text, [switch]$BackslashAware)
    $inQuote = $false; $prevBs = $false
    foreach ($ch in $Text.ToCharArray()) {
        if ($ch -eq [char]34 -and -not ($BackslashAware -and $prevBs)) { $inQuote = -not $inQuote }
        elseif ([char]::IsWhiteSpace($ch) -and -not $inQuote) { return $true }
        $prevBs = ($ch -eq [char]92)
    }
    return $false
}
function ConvertTo-Ps51CommandLine {
    param([string[]]$ArgList, [switch]$BackslashAware)
    $parts = @()
    foreach ($a in $ArgList) {
        if (Test-Ps51NeedQuotes $a -BackslashAware:$BackslashAware) { $parts += ('"' + $a + '"') } else { $parts += $a }
    }
    return ($parts -join ' ')
}
function Split-MsvcrtCommandLine {
    # CommandLineToArgvW / MSVCRT 2008 / Go rules (2n backslashes + quote -> n + toggle; 2n+1 -> n + literal quote).
    param([string]$Line)
    $out = New-Object System.Collections.Generic.List[string]
    $cur = New-Object System.Text.StringBuilder
    $inQ = $false; $have = $false; $i = 0
    while ($i -lt $Line.Length) {
        $c = $Line[$i]
        if ($c -eq [char]92) {
            $n = 0
            while ($i -lt $Line.Length -and $Line[$i] -eq [char]92) { $n++; $i++ }
            if ($i -lt $Line.Length -and $Line[$i] -eq [char]34) {
                [void]$cur.Append(('\' * [int][Math]::Floor($n / 2)))
                if ($n % 2 -eq 1) { [void]$cur.Append('"'); $i++ } else { $inQ = -not $inQ; $i++ }
            } else { [void]$cur.Append(('\' * $n)) }
            $have = $true
            continue
        }
        if ($c -eq [char]34) {
            if ($inQ -and $i + 1 -lt $Line.Length -and $Line[$i + 1] -eq [char]34) { [void]$cur.Append('"'); $i += 2; $have = $true; continue }
            $inQ = -not $inQ; $i++; $have = $true; continue
        }
        if (([char]::IsWhiteSpace($c)) -and -not $inQ) {
            if ($have) { $out.Add($cur.ToString()); [void]$cur.Clear(); $have = $false }
            $i++; continue
        }
        [void]$cur.Append($c); $have = $true; $i++
    }
    if ($have) { $out.Add($cur.ToString()) }
    return $out.ToArray()
}
$cases = @(
    'plain', 'a b', 'E:\My Backup\', 'C:\x y\\', 'F:\', 'D:\HomeVault', 'd"e', '',
    'include "/var/www/html/config/config.php"; echo ($CONFIG["dbuser"] ?? ""), PHP_EOL;',
    'with "quote" and trailing\', '--display-name=张 三', '/src/nextcloud-data/u/files/My Photos/'
)
foreach ($variant in @($false, $true)) {
    # whitespace only after a quote is ambiguous between the two binder variants; covered for the 5.1/6.x one
    if ($variant) { $cases = @($cases) + @('x\"y z') }
    $conv = @($cases | ForEach-Object { ConvertTo-HvNativeArg -Arg $_ -Legacy $true })
    $parsed = @(Split-MsvcrtCommandLine (ConvertTo-Ps51CommandLine -ArgList $conv -BackslashAware:$variant))
    Assert-Eq ('arg count survives (backslash-aware=' + $variant + ')') $cases.Count $parsed.Count
    for ($k = 0; $k -lt [Math]::Min($cases.Count, $parsed.Count); $k++) {
        Assert-Eq ('round trip [' + $cases[$k] + '] (backslash-aware=' + $variant + ')') $cases[$k] $parsed[$k]
    }
}
Assert-Eq 'trailing backslash doubled when wrapped' 'E:\My Backup\\' (ConvertTo-HvNativeArg -Arg 'E:\My Backup\' -Legacy $true)
Assert-Eq 'no whitespace: unchanged' 'F:\' (ConvertTo-HvNativeArg -Arg 'F:\' -Legacy $true)
Assert-Eq 'modern mode: unchanged' 'E:\My Backup\' (ConvertTo-HvNativeArg -Arg 'E:\My Backup\' -Legacy $false)
# the CreateProcess quoting used for direct child processes agrees with the parser too
$direct = @(Split-MsvcrtCommandLine (ConvertTo-HvCommandLine $cases))
Assert-Eq 'ConvertTo-HvCommandLine round trip' ('[' + ($cases -join '|') + ']') ('[' + ($direct -join '|') + ']')

# ------------------------------------------------------------------ panel mounts
Section 'management panel mounts (compose.storage.yaml)'
$pm = @(Get-HvPanelStatMounts -NcDataPath 'D:\HomeVault\.panel-stat' -StateDir 'C:\HomeVault\state\')
$byTarget = @{}
foreach ($m in $pm) { $byTarget[$m.Target] = $m }
Assert-True 'state mounted read-only' ($byTarget.ContainsKey('/state') -and $byTarget['/state'].ReadOnly -eq $true -and $byTarget['/state'].Source -eq 'C:\HomeVault\state')
Assert-True 'only state\requests writable' ($byTarget['/state/requests'].ReadOnly -eq $false -and $byTarget['/state/requests'].Source -eq 'C:\HomeVault\state\requests')
Assert-True 'state\requests\done read-only' ($byTarget['/state/requests/done'].ReadOnly -eq $true -and $byTarget['/state/requests/done'].Source -eq 'C:\HomeVault\state\requests\done')
$writable = @($pm | Where-Object { -not $_.ReadOnly } | ForEach-Object { $_.Target })
Assert-Eq 'nothing else writable' '/state/requests' ($writable -join '|')
$y = ConvertTo-HvComposeStorageYaml -Rows @() -PanelMounts $pm
Assert-True 'yaml: /state read_only true' ($y.Contains("source: 'C:\HomeVault\state'`n        target: /state`n        read_only: true"))
Assert-True 'yaml: /state/requests read_only false' ($y.Contains("target: /state/requests`n        read_only: false"))
Assert-True 'yaml: done read_only true' ($y.Contains("target: /state/requests/done`n        read_only: true"))
Assert-True 'yaml: mounts without ReadOnly stay read-only' ((ConvertTo-HvComposeStorageYaml -Rows @() -PanelMounts @([pscustomobject]@{ Source = '/x'; Target = '/stat/data'; Comment = '' })).Contains("target: /stat/data`n        read_only: true"))
Assert-Eq 'posix state paths' '/srv/hv/state/requests/done' (@(Get-HvPanelStatMounts -StateDir '/srv/hv/state') | Where-Object { $_.Target -eq '/state/requests/done' }).Source
Assert-Eq 'probe next to the data folder' 'D:\HomeVault\.panel-stat' (Get-HvStatProbePath 'D:\HomeVault\nextcloud-data')
Assert-Eq 'probe trailing separator' 'D:\HomeVault\.panel-stat' (Get-HvStatProbePath 'D:\HomeVault\nextcloud-data\')
Assert-Eq 'probe data at drive root' 'D:\.panel-stat' (Get-HvStatProbePath 'D:\nextcloud-data')
Assert-Eq 'probe posix' '/srv/hv/.panel-stat' (Get-HvStatProbePath '/srv/hv/nextcloud-data')
Assert-Eq 'probe empty' '' (Get-HvStatProbePath '')

# ------------------------------------------------------------------ links planted by the panel
Section 'host writes never follow planted links'
$canLink = $true
$lt = Join-Path $OutDir 'linkcheck'
try { [void](New-Item -ItemType SymbolicLink -Path $lt -Target $OutDir -ErrorAction Stop); Remove-Item -LiteralPath $lt -Force } catch { $canLink = $false }
if (-not $canLink) {
    Write-Host '  (symbolic links not available here - link tests skipped)'
} else {
    $victimDir = Join-Path $OutDir 'victim'
    [void](New-Item -ItemType Directory -Force -Path $victimDir)
    $victim = Join-Path $victimDir 'precious.txt'
    [System.IO.File]::WriteAllText($victim, 'keep me')
    $st = Join-Path $OutDir 'state1'
    [void](New-Item -ItemType Directory -Force -Path $st)
    $dst = Join-Path $st 'status.json'
    [void](New-Item -ItemType SymbolicLink -Path $dst -Target $victim)
    Assert-True 'reparse point detected' (Test-HvReparsePoint $dst)
    Assert-True 'regular file is not a reparse point' (-not (Test-HvReparsePoint $victim))
    Write-HvJsonFile -Path $dst -Value ([ordered]@{ ok = $true })
    Assert-Eq 'link target untouched' 'keep me' ([System.IO.File]::ReadAllText($victim))
    Assert-True 'destination replaced by a regular file' ((-not (Test-HvReparsePoint $dst)) -and ([System.IO.File]::ReadAllText($dst) -match '"ok": true'))
    $t1 = New-HvTempPath $dst; $t2 = New-HvTempPath $dst
    Assert-True 'temp names are unpredictable' ($t1 -ne $t2 -and $t1 -match '[\\/]\.status\.json\.[A-Za-z0-9]{16}\.tmp$')
    # a link already sitting at the temp name makes CreateNew fail instead of writing through it
    $trap = New-HvTempPath $dst
    [void](New-Item -ItemType SymbolicLink -Path $trap -Target $victim)
    $failed = $false
    try { Write-HvNewTextFile -Path $trap -Content 'x' } catch { $failed = $true }
    Assert-True 'CreateNew refuses an existing link' ($failed -and ([System.IO.File]::ReadAllText($victim) -eq 'keep me'))
    Remove-Item -LiteralPath $trap -Force

    # request runner: done\ planted as a link to another folder
    $inst = Join-Path $OutDir 'inst'
    [void](New-Item -ItemType Directory -Force -Path (Join-Path $inst 'state/requests'))
    $script:HvRoot = $inst
    $other = Join-Path $OutDir 'other'
    [void](New-Item -ItemType Directory -Force -Path $other)
    for ($k = 0; $k -lt 205; $k++) { [System.IO.File]::WriteAllText((Join-Path $other ('f' + $k + '.json')), '{}') }
    [System.IO.File]::WriteAllText((Join-Path $other 'photo.jpg'), 'jpeg')
    $reqDir = Join-Path $inst 'state/requests'
    [void](New-Item -ItemType SymbolicLink -Path (Join-Path $reqDir 'done') -Target $other)
    [System.IO.File]::WriteAllText((Join-Path $reqDir '20260926T120000000Z-shell.json'), '{"type":"shell"}', (New-Object System.Text.UTF8Encoding($false)))
    [void](Invoke-HvRequestsProcess)
    $doneReal = Join-Path $reqDir 'done'
    Assert-True 'linked done\ replaced by a real directory' ((-not (Test-HvReparsePoint $doneReal)) -and [System.IO.Directory]::Exists($doneReal))
    Assert-True 'result written into the real done\' (Test-Path -LiteralPath (Join-Path $doneReal '20260926T120000000Z-shell.result.json'))
    Assert-Eq 'files behind the link not deleted' 206 @(Get-ChildItem -LiteralPath $other -File).Count
    Assert-True 'old link moved aside' (@(Get-ChildItem -LiteralPath $reqDir -Force | Where-Object { $_.Name -like '.done-invalid-*' }).Count -eq 1)
    # retention in done\ only touches regular *.json files
    [System.IO.File]::WriteAllText((Join-Path $doneReal 'keep.txt'), 'x')
    [void](New-Item -ItemType SymbolicLink -Path (Join-Path $doneReal 'zz-link.json') -Target $victim)
    Remove-HvOldRequestResults -DoneDir $doneReal -Keep 0
    Assert-True 'non-json file kept' (Test-Path -LiteralPath (Join-Path $doneReal 'keep.txt'))
    Assert-Eq 'link target kept' 'keep me' ([System.IO.File]::ReadAllText($victim))
    Remove-HvOldRequestResults -DoneDir (Join-Path $reqDir (@(Get-ChildItem -LiteralPath $reqDir -Force | Where-Object { $_.Name -like '.done-invalid-*' })[0].Name)) -Keep 0
    Assert-Eq 'retention never follows a linked done\' 206 @(Get-ChildItem -LiteralPath $other -File).Count
    $script:HvRoot = $Root
}

# ------------------------------------------------------------------ backup lock
Section 'backup lock'
$script:HvRoot = Join-Path $OutDir 'lockinst'
[void](New-Item -ItemType Directory -Force -Path (Join-Path $script:HvRoot 'state'))
$lock = Enter-HvBackupLock
try {
    $readable = $false
    try {
        $r = [System.IO.File]::Open((Join-Path $script:HvRoot 'state/backup.lock'), [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
        $r.Dispose(); $readable = $true
    } catch { }
    Assert-True 'lock file stays readable (restic reads the project folder)' $readable
} finally { $lock.Dispose() }
$script:HvRoot = $Root
$ba = @(Get-HvResticBackupArgs -Env ([ordered]@{ HV_BACKUP_TARGET = 'local' }) -Paths @('/src/project'))
Assert-True 'lock file excluded from the snapshot' (($ba -join ' ').Contains('--exclude /src/project/state/backup.lock'))

# ------------------------------------------------------------------ misc
Section 'misc'
$hvText = [System.IO.File]::ReadAllText((Join-Path $Root 'windows/hv.ps1'))
Assert-True 'requests runner does not log every 2 minutes' ($hvText -match "'-v', 'requests'\) -notcontains \`$cmd")
$vpnText = [System.IO.File]::ReadAllText((Join-Path $Root 'windows/lib/vpn.ps1'))
Assert-True 'SYSTEM weak-host task uses the full powershell.exe path' ($vpnText -notmatch "-Execute 'powershell\.exe'")
Assert-Eq 'ProgramData ACL args' 'X|/inheritance:r|/grant:r|*S-1-5-18:(OI)(CI)F|*S-1-5-32-544:(OI)(CI)F|*S-1-5-32-545:(OI)(CI)RX|/Q' ((Get-HvProgramDataAclArgs 'X') -join '|')
$bkText = [System.IO.File]::ReadAllText((Join-Path $Root 'windows/lib/backup.ps1'))
Assert-True 'restore overlay not written into state\' ($bkText -notmatch "'compose\.restore\.yaml'")

Write-Host ''
Write-Host ('unit-sec: ' + $script:Pass + ' passed, ' + $script:Fail + ' failed')
if ($script:Fail -gt 0) { exit 1 }
exit 0
