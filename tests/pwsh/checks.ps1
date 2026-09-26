#Requires -Version 5.1
# Static checks for every HomeVault .ps1 (runs in mcr.microsoft.com/powershell):
#   1. parse errors  2. UTF-8 BOM when non-ASCII  3. Windows PowerShell 5.1 compatibility  4. template placeholders
param([string]$Root = (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)))

$ErrorActionPreference = 'Stop'
$script:Failures = 0
function Report-Fail { param([string]$Msg) $script:Failures++; Write-Host ('  FAIL ' + $Msg) }
function Report-Ok { param([string]$Msg) Write-Host ('  ok   ' + $Msg) }

$files = @()
foreach ($d in @('windows', 'tests/pwsh')) {
    $p = Join-Path $Root $d
    if (Test-Path -LiteralPath $p) { $files += @(Get-ChildItem -LiteralPath $p -Recurse -File -Filter '*.ps1') }
}
if ($files.Count -eq 0) { Report-Fail 'no .ps1 files found'; exit 1 }
$self = (Resolve-Path -LiteralPath $PSCommandPath).Path

# PS7-only syntax detected from the tokenizer / AST (PowerShell 7's parser understands all of them).
$bannedTokens = @('QuestionQuestion', 'QuestionQuestionEquals', 'QuestionDot', 'QuestionLBracket', 'AndAnd', 'OrOr', 'QuestionMark')
$bannedAstTypes = @('TernaryExpressionAst', 'PipelineChainAst')
# PS6+/7-only cmdlet parameters, APIs and risky .NET overloads (text search, this file excluded).
$bannedPatterns = [ordered]@{
    'ConvertFrom-Json -AsHashtable (PS6+)'           = '-AsHashtable\b'
    'utf8NoBOM encoding name (PS6+)'                 = '(?i)utf8NoBOM'
    '-AsByteStream (PS6+)'                           = '-AsByteStream\b'
    'Join-Path -AdditionalChildPath (PS6+)'          = '-AdditionalChildPath\b'
    'Split-Path -LeafBase/-Extension (PS6+)'         = '-LeafBase\b'
    'ConvertFrom-Json -Depth/-NoEnumerate (PS6+)'    = 'ConvertFrom-Json[^\r\n]*-(Depth|NoEnumerate)\b'
    '$IsWindows/$IsLinux/$IsMacOS (PS6+)'            = '\$Is(Windows|Linux|MacOS)\b'
    '-SkipCertificateCheck (PS6+)'                   = '-SkipCertificateCheck\b'
    'Get-Date -AsUTC (PS7)'                          = '-AsUTC\b'
    'RandomNumberGenerator.GetInt32/Fill (.NET Core)' = 'RandomNumberGenerator\]::(GetInt32|Fill|GetBytes)\('
    'String.Split(...) differs between .NET versions (use -split)' = '\.Split\('
    'Test-Json (PS6+)'                               = '\bTest-Json\b'
    'ForEach-Object -Parallel (PS7)'                 = '-Parallel\b'
    'Join-String (PS6+)'                             = '\bJoin-String\b'
    'Get-Error (PS7)'                                = '\bGet-Error\b'
    '$PSStyle (PS7.2)'                               = '\$PSStyle\b'
    '-SkipHttpErrorCheck / -ResponseHeadersVariable (PS7)' = '-(SkipHttpErrorCheck|ResponseHeadersVariable)\b'
    'Out-File/Set-Content -Encoding utf8 writes a BOM on 5.1 (use Write-HvTextFile)' = '(?i)(Set-Content|Out-File|Add-Content)[^\r\n]*-Encoding'
    '$PSNativeCommandUseErrorActionPreference (PS7.3)' = '\$PSNativeCommandUseErrorActionPreference\s*='
}

function Get-AllTokens {
    param($Tokens)
    foreach ($t in $Tokens) {
        $t
        if ($t.PSObject.Properties['NestedTokens'] -and $t.NestedTokens) { Get-AllTokens $t.NestedTokens }
    }
}

Write-Host '== PowerShell static checks'
foreach ($f in $files) {
    $rel = $f.FullName.Substring($Root.Length).TrimStart('/', '\')
    $bytes = [System.IO.File]::ReadAllBytes($f.FullName)
    $hasBom = ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
    $nonAscii = $false
    foreach ($b in $bytes) { if ($b -gt 127) { $nonAscii = $true; break } }
    if ($nonAscii -and -not $hasBom) { Report-Fail ($rel + ': contains non-ASCII but has no UTF-8 BOM (Windows PowerShell 5.1 would read it as ANSI/GBK)') }
    try { [void](New-Object System.Text.UTF8Encoding($false, $true)).GetString($bytes) } catch { Report-Fail ($rel + ': not valid UTF-8') }

    $tokens = $null; $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$tokens, [ref]$errors)
    if ($errors -and $errors.Count -gt 0) {
        foreach ($e in $errors) { Report-Fail ($rel + ':' + $e.Extent.StartLineNumber + ': parse error: ' + $e.Message) }
        continue
    }
    $bad = 0
    foreach ($t in (Get-AllTokens $tokens)) {
        $kind = [string]$t.Kind
        if ($bannedTokens -contains $kind) { Report-Fail ($rel + ':' + $t.Extent.StartLineNumber + ': PS7-only operator ' + $t.Text); $bad++ }
        if ($kind -eq 'Variable' -or $kind -eq 'SplattedVariable') {
            if ($t.Name -match '[^\x00-\x7F]') { Report-Fail ($rel + ':' + $t.Extent.StartLineNumber + ': variable name contains non-ASCII (' + $t.Text + ') - use ${var} or $($var) before Chinese text'); $bad++ }
        }
    }
    $nodes = $ast.FindAll({ param($n) $true }, $true)
    foreach ($n in $nodes) {
        $tn = $n.GetType().Name
        if ($bannedAstTypes -contains $tn) { Report-Fail ($rel + ':' + $n.Extent.StartLineNumber + ': PS7-only syntax ' + $tn); $bad++ }
        if ($n -is [System.Management.Automation.Language.ScriptBlockAst] -and $n.PSObject.Properties['CleanBlock'] -and $null -ne $n.CleanBlock) {
            Report-Fail ($rel + ': clean {} block (PS7.3+)'); $bad++
        }
        if ($n -is [System.Management.Automation.Language.CommandAst]) {
            $name = $n.GetCommandName()
            if (@('ForEach-Object', 'foreach', '%') -contains $name) {
                foreach ($el in $n.CommandElements) {
                    if ($el -is [System.Management.Automation.Language.CommandParameterAst] -and $el.ParameterName -like 'Pa*') { Report-Fail ($rel + ':' + $n.Extent.StartLineNumber + ': ForEach-Object -Parallel (PS7)'); $bad++ }
                }
            }
        }
    }
    if ($f.FullName -ne $self) {
        $text = [System.IO.File]::ReadAllText($f.FullName)
        $lines = $text -split "`n"
        foreach ($k in $bannedPatterns.Keys) {
            for ($i = 0; $i -lt $lines.Count; $i++) {
                $l = $lines[$i]
                if ($l.TrimStart().StartsWith('#')) { continue }
                if ($l -match $bannedPatterns[$k]) { Report-Fail ($rel + ':' + ($i + 1) + ': ' + $k); $bad++ }
            }
        }
    }
    if ($rel -match '^windows[/\\](hv|install)\.ps1$') {
        if ($text -notmatch '(?m)^#Requires -Version 5\.1') { Report-Fail ($rel + ': missing #Requires -Version 5.1'); $bad++ }
    }
    if ($bad -eq 0 -and -not ($nonAscii -and -not $hasBom)) { Report-Ok $rel }
}

Write-Host '== templates'
$tpl = Join-Path $Root 'windows/templates/vpn-qr.html'
if (-not (Test-Path -LiteralPath $tpl)) { Report-Fail 'windows/templates/vpn-qr.html missing' }
else {
    $t = [System.IO.File]::ReadAllText($tpl)
    foreach ($ph in @('{{HV_QRCODE_JS}}', '{{HV_CONFIG_JSON}}', '{{HV_FILENAME_JSON}}', '{{HV_PEER_NAME}}', '{{HV_ENDPOINT}}', '{{HV_ADDRESS}}', '{{HV_GENERATED_AT}}')) {
        if (-not $t.Contains($ph)) { Report-Fail ('vpn-qr.html: placeholder ' + $ph + ' missing') }
    }
    if ($t -match '(?i)<(script|link|img)[^>]+(src|href)\s*=\s*"https?:') { Report-Fail 'vpn-qr.html must not load remote resources' } else { Report-Ok 'windows/templates/vpn-qr.html' }
}
$qr = Join-Path $Root 'windows/vendor/qrcode.js'
if (-not (Test-Path -LiteralPath $qr)) { Report-Fail 'windows/vendor/qrcode.js missing' }
elseif ([System.IO.File]::ReadAllText($qr) -match '</script') { Report-Fail 'qrcode.js contains </script' }
else { Report-Ok 'windows/vendor/qrcode.js' }

if ($script:Failures -gt 0) { Write-Host ('static checks: ' + $script:Failures + ' failure(s)'); exit 1 }
Write-Host 'static checks: all passed'
exit 0
