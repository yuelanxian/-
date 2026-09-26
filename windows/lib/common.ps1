# HomeVault Windows CLI - common helpers (output, argument parsing, prompts, files, processes).
# Compatible with Windows PowerShell 5.1 and PowerShell 7. Pure helpers here are unit-tested.

$script:HvVersion = '1.0.0'
if (-not (Get-Variable -Name HvRoot -Scope Script -ErrorAction SilentlyContinue)) { $script:HvRoot = $null }
if (-not (Get-Variable -Name HvYes -Scope Script -ErrorAction SilentlyContinue)) { $script:HvYes = $false }
if (-not (Get-Variable -Name HvNonInteractive -Scope Script -ErrorAction SilentlyContinue)) { $script:HvNonInteractive = $false }
if (-not (Get-Variable -Name HvLogFile -Scope Script -ErrorAction SilentlyContinue)) { $script:HvLogFile = $null }

# ---------------------------------------------------------------- output

function Write-HvLog {
    param([AllowEmptyString()][string]$Text)
    if (-not $script:HvLogFile) { return }
    try {
        $line = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss') + ' ' + $Text + "`n"
        [System.IO.File]::AppendAllText($script:HvLogFile, $line, (New-Object System.Text.UTF8Encoding($false)))
    } catch { }
}

function Write-HvMsg {
    param([string]$Prefix, [AllowEmptyString()][string]$Text, [string]$Color)
    if ($Color) { Write-Host ($Prefix + $Text) -ForegroundColor $Color } else { Write-Host ($Prefix + $Text) }
    Write-HvLog ($Prefix + $Text)
}

function Write-HvStep { param([AllowEmptyString()][string]$Text) Write-HvMsg '==> ' $Text 'Cyan' }
function Write-HvInfo { param([AllowEmptyString()][string]$Text) Write-HvMsg '    ' $Text '' }
function Write-HvOk { param([AllowEmptyString()][string]$Text) Write-HvMsg ([string][char]0x2714 + ' ') $Text 'Green' }
function Write-HvWarn { param([AllowEmptyString()][string]$Text) Write-HvMsg '! ' $Text 'Yellow' }
function Write-HvErr { param([AllowEmptyString()][string]$Text) Write-HvMsg ([string][char]0x2718 + ' ') $Text 'Red' }

function Stop-Hv {
    # Abort the current command with a Chinese message and an exit code (caught in hv.ps1).
    param([string]$Message, [int]$ExitCode = 1)
    $ex = New-Object System.Exception $Message
    $ex.Data['HvExitCode'] = $ExitCode
    throw $ex
}

function Get-HvExitCodeFromError {
    param($ErrorRecord)
    $e = $ErrorRecord
    if ($e -is [System.Management.Automation.ErrorRecord]) { $e = $e.Exception }
    while ($null -ne $e) {
        if ($e.Data -and $e.Data.Contains('HvExitCode')) { return [int]$e.Data['HvExitCode'] }
        $e = $e.InnerException
    }
    return 1
}

function Get-HvErrorMessage {
    param($ErrorRecord)
    $e = $ErrorRecord
    if ($e -is [System.Management.Automation.ErrorRecord]) { $e = $e.Exception }
    $cur = $e
    while ($null -ne $cur) {
        if ($cur.Data -and $cur.Data.Contains('HvExitCode')) { return $cur.Message }
        $cur = $cur.InnerException
    }
    return $e.Message
}

# ---------------------------------------------------------------- platform

function Test-HvWindows {
    return ([System.Environment]::OSVersion.Platform -eq [System.PlatformID]::Win32NT)
}

function Test-HvAdmin {
    if (-not (Test-HvWindows)) { return $false }
    $id = [System.Security.Principal.WindowsIdentity]::GetCurrent()
    $p = New-Object System.Security.Principal.WindowsPrincipal($id)
    return $p.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Assert-HvWindows {
    param([string]$What)
    if (-not (Test-HvWindows)) { Stop-Hv ('“' + $What + '”只能在 Windows 上运行（Linux 请使用仓库根目录的 ./hv）。') }
}

function Assert-HvAdmin {
    param([string]$What)
    Assert-HvWindows $What
    if (-not (Test-HvAdmin)) {
        Stop-Hv ('此操作（' + $What + '）需要管理员权限：请在开始菜单右键“Windows PowerShell”或“终端”，选择“以管理员身份运行”，然后重新执行该命令。') 5
    }
}

function Get-HvCurrentUserSid {
    if (-not (Test-HvWindows)) { return $null }
    return [System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value
}

function Get-HvCurrentUserName {
    if (Test-HvWindows) { return [System.Security.Principal.WindowsIdentity]::GetCurrent().Name }
    return [System.Environment]::UserName
}

# ---------------------------------------------------------------- argument parsing

function Get-HvArgKey {
    param([string]$Name)
    return ($Name -replace '[-_]', '').ToLowerInvariant()
}

function ConvertTo-HvArgString {
    # PowerShell turns unquoted 500GB into a number and a,b into an array - normalise back to text.
    param($Value)
    if ($null -eq $Value) { return '' }
    if ($Value -is [System.Array]) {
        $parts = @()
        foreach ($v in $Value) { $parts += (ConvertTo-HvArgString $v) }
        return ($parts -join ',')
    }
    if ($Value -is [bool]) { if ($Value) { return 'true' } else { return 'false' } }
    if ($Value -is [System.Management.Automation.SwitchParameter]) { if ($Value.IsPresent) { return 'true' } else { return 'false' } }
    return [string]$Value
}

function ConvertFrom-HvArgs {
    # Pure parser. Accepts --long-name value, --long-name=value, -LongName value, -LongName:value.
    # Returns @{ Positional = string[]; Opts = hashtable(normalised key -> $true | string | string[]) }.
    param(
        [object[]]$Arguments = @(),
        [string[]]$Switches = @(),
        [string[]]$Options = @(),
        [string[]]$MultiOptions = @()
    )
    $sw = @{}; foreach ($n in (@($Switches) + @('yes', 'y', 'non-interactive', 'help', 'h'))) { if ($n) { $sw[(Get-HvArgKey $n)] = $true } }
    $op = @{}; foreach ($n in @($Options)) { if ($n) { $op[(Get-HvArgKey $n)] = $true } }
    $mu = @{}; foreach ($n in @($MultiOptions)) { if ($n) { $mu[(Get-HvArgKey $n)] = $true } }
    $pos = New-Object System.Collections.Generic.List[string]
    $opts = @{}
    $args2 = @($Arguments)
    $i = 0
    while ($i -lt $args2.Count) {
        $raw = $args2[$i]
        $s = ConvertTo-HvArgString $raw
        if (($raw -is [string]) -and ($s -match '^--?([A-Za-z][A-Za-z0-9_-]*)(?:([=:])(.*))?$')) {
            $key = Get-HvArgKey $Matches[1]
            $hasInline = [bool]$Matches[2]
            $inline = $Matches[3]
            if ($sw.ContainsKey($key)) {
                if ($hasInline -and $inline -ne '') {
                    $opts[$key] = -not ($inline -match '^(?i)(false|0|no|\$false)$')
                } else {
                    $opts[$key] = $true
                }
            } elseif ($op.ContainsKey($key) -or $mu.ContainsKey($key)) {
                if ($hasInline -and $inline -ne '') {
                    $val = $inline
                } else {
                    $i++
                    if ($i -ge $args2.Count) { throw ('参数 ' + $s + ' 需要一个值。') }
                    $val = ConvertTo-HvArgString $args2[$i]
                }
                if ($mu.ContainsKey($key)) {
                    if (-not $opts.ContainsKey($key)) { $opts[$key] = @() }
                    $opts[$key] = @($opts[$key]) + @($val)
                } else {
                    $opts[$key] = $val
                }
            } else {
                throw ('未知参数：' + $s + '（运行 help 查看用法）')
            }
        } else {
            $pos.Add($s)
        }
        $i++
    }
    return @{ Positional = $pos.ToArray(); Opts = $opts }
}

function Read-HvCommandArgs {
    # Parse and apply global switches (--yes / --non-interactive).
    param(
        [object[]]$Arguments = @(),
        [string[]]$Switches = @(),
        [string[]]$Options = @(),
        [string[]]$MultiOptions = @()
    )
    try {
        $p = ConvertFrom-HvArgs -Arguments $Arguments -Switches $Switches -Options $Options -MultiOptions $MultiOptions
    } catch {
        Stop-Hv $_.Exception.Message 2
    }
    if ($p.Opts.ContainsKey('yes') -or $p.Opts.ContainsKey('y')) { $script:HvYes = $true }
    if ($p.Opts.ContainsKey('noninteractive')) { $script:HvNonInteractive = $true }
    return $p
}

function Get-HvOpt {
    param([hashtable]$Parsed, [string]$Name, $Default = $null)
    $k = Get-HvArgKey $Name
    if ($Parsed.Opts.ContainsKey($k)) { return $Parsed.Opts[$k] }
    return $Default
}

function Test-HvOpt {
    param([hashtable]$Parsed, [string]$Name)
    $k = Get-HvArgKey $Name
    if (-not $Parsed.Opts.ContainsKey($k)) { return $false }
    $v = $Parsed.Opts[$k]
    if ($v -is [bool]) { return $v }
    return $true
}

function Test-HvTrue {
    param($Value)
    if ($null -eq $Value) { return $false }
    if ($Value -is [bool]) { return $Value }
    return ([string]$Value -match '^(?i)\s*(true|1|yes|on|y)\s*$')
}

# ---------------------------------------------------------------- prompts

function Test-HvInteractive {
    if ($script:HvNonInteractive) { return $false }
    if (-not [System.Environment]::UserInteractive) { return $false }
    try { if ([System.Console]::IsInputRedirected) { return $false } } catch { }
    return $true
}

function Read-HvYesNo {
    # --yes answers yes; non-interactive mode takes the default.
    param([string]$Question, [bool]$Default = $false)
    if ($script:HvYes) { return $true }
    if (-not (Test-HvInteractive)) { return $Default }
    $hint = '[y/N]'
    if ($Default) { $hint = '[Y/n]' }
    while ($true) {
        $ans = Read-Host ($Question + ' ' + $hint)
        if ([string]::IsNullOrWhiteSpace($ans)) { return $Default }
        $a = $ans.Trim().ToLowerInvariant()
        if (@('y', 'yes', '是', '好', '确认') -contains $a) { return $true }
        if (@('n', 'no', '否', '不') -contains $a) { return $false }
        Write-HvWarn '请输入 y（是）或 n（否）。'
    }
}

function Read-HvValue {
    param(
        [string]$Prompt,
        [AllowEmptyString()][string]$Default = '',
        [scriptblock]$Validate = $null,
        [string]$ErrorText = '输入无效，请重新输入。'
    )
    if (-not (Test-HvInteractive)) {
        if ($null -ne $Validate -and -not (& $Validate $Default)) {
            Stop-Hv ($Prompt + '：缺少有效值（非交互模式请用命令行参数提供）。') 2
        }
        return $Default
    }
    while ($true) {
        $p = $Prompt
        if ($Default) { $p = $Prompt + ' [' + $Default + ']' }
        $v = Read-Host $p
        if ([string]::IsNullOrWhiteSpace($v)) { $v = $Default } else { $v = $v.Trim() }
        if ($null -eq $Validate -or (& $Validate $v)) { return $v }
        Write-HvWarn $ErrorText
    }
}

function Read-HvSecretValue {
    param([string]$Prompt, [string]$EnvName = '')
    if ($EnvName) {
        $fromEnv = [System.Environment]::GetEnvironmentVariable($EnvName)
        if ($fromEnv) { return $fromEnv }
    }
    if (-not (Test-HvInteractive)) {
        Stop-Hv ($Prompt + '：非交互模式下请通过环境变量 ' + $EnvName + ' 提供。') 2
    }
    while ($true) {
        $sec = Read-Host -AsSecureString $Prompt
        $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec)
        try { $plain = [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) } finally { [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
        if ($plain) { return $plain }
        Write-HvWarn '不能为空。'
    }
}

function Read-HvConfirmPhrase {
    # Strong confirmation: the user must type the phrase exactly (skipped by --yes).
    param([string]$Question, [string]$Phrase)
    if ($script:HvYes) { return $true }
    if (-not (Test-HvInteractive)) { return $false }
    $ans = Read-Host ($Question + '（请输入 ' + $Phrase + ' 确认）')
    return ($ans -ceq $Phrase)
}

# ---------------------------------------------------------------- paths & files

function Get-HvRoot {
    if (-not $script:HvRoot) { Stop-Hv '内部错误：未设置项目根目录。' }
    return $script:HvRoot
}

function Join-HvPath {
    param([string]$Base, [string]$Child)
    return [System.IO.Path]::Combine($Base, $Child)
}

function Get-HvPath {
    param([string]$Relative)
    return (Join-HvPath (Get-HvRoot) $Relative)
}

function ConvertTo-HvLf {
    param([AllowEmptyString()][string]$Text)
    return ($Text -replace "`r`n", "`n")
}

function Write-HvTextFile {
    # UTF-8 (no BOM unless -Bom) with LF line endings - for .env, storage.conf, YAML, WireGuard confs.
    param([Parameter(Mandatory = $true)][string]$Path, [AllowEmptyString()][string]$Content, [switch]$Bom)
    $dir = [System.IO.Path]::GetDirectoryName($Path)
    if ($dir -and -not [System.IO.Directory]::Exists($dir)) { [void][System.IO.Directory]::CreateDirectory($dir) }
    $enc = New-Object System.Text.UTF8Encoding($Bom.IsPresent)
    [System.IO.File]::WriteAllText($Path, (ConvertTo-HvLf $Content), $enc)
}

function Read-HvTextFile {
    param([Parameter(Mandatory = $true)][string]$Path)
    return [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8)
}

function New-HvDirectory {
    param([Parameter(Mandatory = $true)][string]$Path)
    if (-not [System.IO.Directory]::Exists($Path)) { [void][System.IO.Directory]::CreateDirectory($Path) }
    return $Path
}

# ---------------------------------------------------------------- crypto helpers

function New-HvRandomString {
    # CSPRNG, rejection sampling (no modulo bias).
    param([int]$Length = 32, [string]$Alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789')
    $n = $Alphabet.Length
    $limit = 256 - (256 % $n)
    $sb = New-Object System.Text.StringBuilder
    $buf = New-Object byte[] 64
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    try {
        while ($sb.Length -lt $Length) {
            $rng.GetBytes($buf)
            foreach ($b in $buf) {
                if ($b -lt $limit) {
                    [void]$sb.Append($Alphabet[$b % $n])
                    if ($sb.Length -ge $Length) { break }
                }
            }
        }
    } finally {
        $rng.Dispose()
    }
    return $sb.ToString()
}

function Get-HvSha256Hex {
    param([AllowEmptyString()][string]$Text)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { $bytes = $sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($Text)) } finally { $sha.Dispose() }
    $sb = New-Object System.Text.StringBuilder
    foreach ($b in $bytes) { [void]$sb.Append($b.ToString('x2')) }
    return $sb.ToString()
}

function Get-HvBytesSha256Hex {
    param([byte[]]$Bytes)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { $hash = $sha.ComputeHash($Bytes) } finally { $sha.Dispose() }
    $sb = New-Object System.Text.StringBuilder
    foreach ($b in $hash) { [void]$sb.Append($b.ToString('x2')) }
    return $sb.ToString()
}

# ---------------------------------------------------------------- native processes

function Test-HvLegacyArgPassing {
    # Windows PowerShell 5.1 (and PS < 7.3 / Legacy mode) do not escape embedded quotes for native programs.
    $v = Get-Variable -Name PSNativeCommandArgumentPassing -ValueOnly -ErrorAction SilentlyContinue
    if ($null -eq $v) { return $true }
    return ([string]$v -eq 'Legacy')
}

function ConvertTo-HvNativeArg {
    param([AllowEmptyString()][string]$Arg, [bool]$Legacy = $true)
    if (-not $Legacy) { return $Arg }
    if ($Arg -eq '') { return '""' }
    if ($Arg.IndexOf('"') -lt 0) { return $Arg }
    $sb = New-Object System.Text.StringBuilder
    $bs = 0
    foreach ($ch in $Arg.ToCharArray()) {
        if ($ch -eq [char]92) { $bs++; continue }
        if ($ch -eq [char]34) {
            [void]$sb.Append(('\' * ($bs * 2 + 1)))
            [void]$sb.Append('"')
            $bs = 0
            continue
        }
        if ($bs -gt 0) { [void]$sb.Append(('\' * $bs)); $bs = 0 }
        [void]$sb.Append($ch)
    }
    if ($bs -gt 0) { [void]$sb.Append(('\' * $bs)) }
    return $sb.ToString()
}

function ConvertTo-HvCommandLineArg {
    # Quote one argument for CreateProcess (MSVCRT / Go rules).
    param([AllowEmptyString()][string]$Arg)
    if ($Arg -eq '') { return '""' }
    if ($Arg -notmatch '[\s"]') { return $Arg }
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append('"')
    $bs = 0
    foreach ($ch in $Arg.ToCharArray()) {
        if ($ch -eq [char]92) { $bs++; continue }
        if ($ch -eq [char]34) {
            [void]$sb.Append(('\' * ($bs * 2 + 1)))
            [void]$sb.Append('"')
            $bs = 0
            continue
        }
        if ($bs -gt 0) { [void]$sb.Append(('\' * $bs)); $bs = 0 }
        [void]$sb.Append($ch)
    }
    if ($bs -gt 0) { [void]$sb.Append(('\' * ($bs * 2))) }
    [void]$sb.Append('"')
    return $sb.ToString()
}

function ConvertTo-HvCommandLine {
    param([string[]]$ArgumentList = @())
    $parts = @()
    foreach ($a in @($ArgumentList)) { $parts += (ConvertTo-HvCommandLineArg $a) }
    return ($parts -join ' ')
}

function Invoke-HvNative {
    # Run a native program. Default: output goes straight to the console.
    # -Capture: return stdout lines (stderr kept separately). -Tee: stream through the host (and the log file).
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [string[]]$ArgumentList = @(),
        [switch]$Capture,
        [switch]$Quiet,
        [switch]$Tee,
        [switch]$AllowFailure,
        [AllowNull()][string]$InputText = $null
    )
    if (-not (Get-Command $FilePath -ErrorAction SilentlyContinue)) {
        Stop-Hv ('找不到程序：' + $FilePath) 127
    }
    $legacy = Test-HvLegacyArgPassing
    $argv = @()
    foreach ($a in @($ArgumentList)) { $argv += (ConvertTo-HvNativeArg -Arg $a -Legacy $legacy) }
    $stdout = New-Object System.Collections.Generic.List[string]
    $stderr = New-Object System.Collections.Generic.List[string]
    $oldEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $code = 0
    try {
        $global:LASTEXITCODE = 0
        if ($Tee) {
            if ($null -ne $InputText) {
                $InputText | & $FilePath @argv 2>&1 | ForEach-Object {
                    $line = $_
                    if ($line -is [System.Management.Automation.ErrorRecord]) { $line = $line.Exception.Message }
                    Write-Host ([string]$line); Write-HvLog ([string]$line); $stdout.Add([string]$line)
                }
            } else {
                & $FilePath @argv 2>&1 | ForEach-Object {
                    $line = $_
                    if ($line -is [System.Management.Automation.ErrorRecord]) { $line = $line.Exception.Message }
                    Write-Host ([string]$line); Write-HvLog ([string]$line); $stdout.Add([string]$line)
                }
            }
        } elseif ($Capture -or $Quiet) {
            if ($null -ne $InputText) { $items = $InputText | & $FilePath @argv 2>&1 } else { $items = & $FilePath @argv 2>&1 }
            foreach ($it in @($items)) {
                if ($null -eq $it) { continue }
                if ($it -is [System.Management.Automation.ErrorRecord]) { $stderr.Add([string]$it.Exception.Message) } else { $stdout.Add([string]$it) }
            }
        } else {
            if ($null -ne $InputText) { $InputText | & $FilePath @argv } else { & $FilePath @argv }
        }
        $code = $LASTEXITCODE
        if ($null -eq $code) { $code = 0 }
    } finally {
        $ErrorActionPreference = $oldEap
    }
    if ($code -ne 0 -and -not $AllowFailure) {
        foreach ($l in $stderr) { Write-HvErr $l }
        Stop-Hv ('命令执行失败（退出码 ' + $code + '）：' + $FilePath + ' ' + (@($ArgumentList) -join ' ')) $code
    }
    return [pscustomobject]@{
        ExitCode = [int]$code
        Output   = $stdout.ToArray()
        StdErr   = $stderr.ToArray()
        Text     = ($stdout.ToArray() -join "`n")
    }
}

function Invoke-HvNativeToFile {
    # Byte-exact stdout -> file (PowerShell's own redirection would re-encode large dumps).
    param([Parameter(Mandatory = $true)][string]$FilePath, [string[]]$ArgumentList = @(), [Parameter(Mandatory = $true)][string]$OutFile)
    $cmd = Get-Command $FilePath -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $cmd) { Stop-Hv ('找不到程序：' + $FilePath) 127 }
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $cmd.Path
    $psi.Arguments = ConvertTo-HvCommandLine $ArgumentList
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $p = [System.Diagnostics.Process]::Start($psi)
    $fs = [System.IO.File]::Create($OutFile)
    try { $p.StandardOutput.BaseStream.CopyTo($fs) } finally { $fs.Dispose() }
    $p.WaitForExit()
    return $p.ExitCode
}

# ---------------------------------------------------------------- misc pure helpers

function Compare-HvVersion {
    # Returns -1 / 0 / 1 comparing dotted numeric versions ("4.92.0" vs "4.9").
    param([string]$A, [string]$B)
    $pa = @(([regex]::Matches($A, '\d+')) | ForEach-Object { [int]$_.Value })
    $pb = @(([regex]::Matches($B, '\d+')) | ForEach-Object { [int]$_.Value })
    $n = [Math]::Max($pa.Count, $pb.Count)
    for ($i = 0; $i -lt $n; $i++) {
        $x = 0; $y = 0
        if ($i -lt $pa.Count) { $x = $pa[$i] }
        if ($i -lt $pb.Count) { $y = $pb[$i] }
        if ($x -lt $y) { return -1 }
        if ($x -gt $y) { return 1 }
    }
    return 0
}

function Get-HvDisplayWidth {
    # East-Asian wide characters take two console columns.
    param([AllowEmptyString()][string]$Text)
    $w = 0
    foreach ($ch in $Text.ToCharArray()) {
        $c = [int]$ch
        if (($c -ge 0x1100 -and $c -le 0x115F) -or ($c -ge 0x2E80 -and $c -le 0xA4CF) -or ($c -ge 0xAC00 -and $c -le 0xD7A3) -or
            ($c -ge 0xF900 -and $c -le 0xFAFF) -or ($c -ge 0xFE30 -and $c -le 0xFE4F) -or ($c -ge 0xFF00 -and $c -le 0xFF60) -or
            ($c -ge 0xFFE0 -and $c -le 0xFFE6)) { $w += 2 } else { $w += 1 }
    }
    return $w
}

function Format-HvPad {
    param([AllowEmptyString()][string]$Text, [int]$Width)
    $pad = $Width - (Get-HvDisplayWidth $Text)
    if ($pad -lt 0) { $pad = 0 }
    return ($Text + (' ' * $pad))
}

function Format-HvTable {
    # Rows: objects/hashtables; Columns: property names; Headers: display names. Returns text lines.
    param([object[]]$Rows = @(), [string[]]$Columns, [string[]]$Headers)
    $cells = New-Object System.Collections.Generic.List[object]
    foreach ($r in @($Rows)) {
        $line = @()
        foreach ($c in $Columns) {
            $v = $null
            if ($r -is [System.Collections.IDictionary]) { $v = $r[$c] } else { $v = $r.$c }
            $line += [string]$v
        }
        $cells.Add($line)
    }
    $widths = @()
    for ($i = 0; $i -lt $Columns.Count; $i++) {
        $w = Get-HvDisplayWidth $Headers[$i]
        foreach ($line in $cells) { $lw = Get-HvDisplayWidth $line[$i]; if ($lw -gt $w) { $w = $lw } }
        $widths += $w
    }
    $out = New-Object System.Collections.Generic.List[string]
    $h = @(); $sep = @()
    for ($i = 0; $i -lt $Columns.Count; $i++) { $h += (Format-HvPad $Headers[$i] $widths[$i]); $sep += ('-' * $widths[$i]) }
    $out.Add((($h -join ' | ').TrimEnd()))
    $out.Add(($sep -join '-+-'))
    foreach ($line in $cells) {
        $parts = @()
        for ($i = 0; $i -lt $Columns.Count; $i++) { $parts += (Format-HvPad $line[$i] $widths[$i]) }
        $out.Add((($parts -join ' | ').TrimEnd()))
    }
    return $out.ToArray()
}

function ConvertTo-HvSizeText {
    param([double]$Bytes)
    if ($Bytes -lt 0) { return '?' }
    $units = @('B', 'KB', 'MB', 'GB', 'TB', 'PB')
    $i = 0
    $v = $Bytes
    while ($v -ge 1024 -and $i -lt ($units.Count - 1)) { $v = $v / 1024; $i++ }
    if ($i -eq 0) { return ('{0} B' -f [int64]$v) }
    return ([string]::Format([System.Globalization.CultureInfo]::InvariantCulture, '{0:0.0} {1}', $v, $units[$i]))
}

function ConvertTo-HvJsonString {
    # JSON string literal; also escapes < > & so the result is safe inside an HTML <script>.
    param([AllowEmptyString()][string]$Text)
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append('"')
    foreach ($ch in $Text.ToCharArray()) {
        $c = [int]$ch
        if ($c -eq 34) { [void]$sb.Append('\"') }
        elseif ($c -eq 92) { [void]$sb.Append('\\') }
        elseif ($c -eq 10) { [void]$sb.Append('\n') }
        elseif ($c -eq 13) { [void]$sb.Append('\r') }
        elseif ($c -eq 9) { [void]$sb.Append('\t') }
        elseif ($c -lt 32 -or $c -eq 60 -or $c -eq 62 -or $c -eq 38 -or $c -eq 0x2028 -or $c -eq 0x2029) { [void]$sb.Append(('\u{0:x4}' -f $c)) }
        else { [void]$sb.Append($ch) }
    }
    [void]$sb.Append('"')
    return $sb.ToString()
}

function ConvertFrom-HvJsonArrayText {
    # Accepts a JSON array or NDJSON (one object per line); returns the items (PS 5.1 safe).
    param([AllowEmptyString()][string]$Text)
    $t = ([string]$Text).Trim()
    $items = New-Object System.Collections.Generic.List[object]
    if ($t -eq '') { return $items.ToArray() }
    if ($t.StartsWith('[')) {
        $parsed = ConvertFrom-Json -InputObject $t
        foreach ($p in $parsed) { if ($null -ne $p) { $items.Add($p) } }
    } else {
        foreach ($line in ($t -split "`r?`n")) {
            $l = $line.Trim()
            if ($l.StartsWith('{')) { $items.Add((ConvertFrom-Json -InputObject $l)) }
        }
    }
    return $items.ToArray()
}

function Get-HvJsonSlice {
    # Extract the first JSON value ({...} or [...]) from text that may contain warnings before/after it.
    param([AllowEmptyString()][string]$Text)
    $t = [string]$Text
    $i1 = $t.IndexOf('{'); $i2 = $t.IndexOf('[')
    $start = -1
    if ($i1 -ge 0 -and ($i2 -lt 0 -or $i1 -lt $i2)) { $start = $i1; $endCh = '}' } elseif ($i2 -ge 0) { $start = $i2; $endCh = ']' }
    if ($start -lt 0) { return '' }
    $end = $t.LastIndexOf($endCh)
    if ($end -lt $start) { return '' }
    return $t.Substring($start, $end - $start + 1)
}

function Get-HvPropValue {
    # Safe property access for PSCustomObject / hashtable (no StrictMode surprises).
    param($Object, [string]$Name, $Default = $null)
    if ($null -eq $Object) { return $Default }
    if ($Object -is [System.Collections.IDictionary]) {
        if ($Object.Contains($Name)) { return $Object[$Name] }
        return $Default
    }
    $p = $Object.PSObject.Properties[$Name]
    if ($null -eq $p) { return $Default }
    return $p.Value
}
