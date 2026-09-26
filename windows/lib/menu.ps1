# HomeVault Windows CLI - numbered Chinese management menu (SPEC section 17): `hv.ps1 menu`, opened by double-clicking
# windows\HomeVault管理.cmd or the desktop shortcut "HomeVault 管理". Every item calls the matching hv command function.

# ---------------------------------------------------------------- pure helpers

function Get-HvMenuItems {
    # Pure: menu entries in display order (Key, Label, Handler = function name; 0 = exit).
    return @(
        [pscustomobject]@{ Key = '1'; Label = '状态'; Handler = 'Invoke-HvMenuStatus' }
        [pscustomobject]@{ Key = '2'; Label = '启动'; Handler = 'Invoke-HvMenuUp' }
        [pscustomobject]@{ Key = '3'; Label = '停止'; Handler = 'Invoke-HvMenuDown' }
        [pscustomobject]@{ Key = '4'; Label = '查看日志'; Handler = 'Invoke-HvMenuLogs' }
        [pscustomobject]@{ Key = '5'; Label = '日志保留天数'; Handler = 'Invoke-HvMenuLogRetention' }
        [pscustomobject]@{ Key = '6'; Label = '添加手机VPN'; Handler = 'Invoke-HvMenuVpnAdd' }
        [pscustomobject]@{ Key = '7'; Label = 'VPN设备列表'; Handler = 'Invoke-HvMenuVpnList' }
        [pscustomobject]@{ Key = '8'; Label = '立即备份'; Handler = 'Invoke-HvMenuBackup' }
        [pscustomobject]@{ Key = '9'; Label = '备份记录'; Handler = 'Invoke-HvMenuBackupHistory' }
        [pscustomobject]@{ Key = '10'; Label = '存储/硬盘'; Handler = 'Invoke-HvMenuStorage' }
        [pscustomobject]@{ Key = '11'; Label = '打开管理面板'; Handler = 'Invoke-HvMenuPanel' }
        [pscustomobject]@{ Key = '12'; Label = '打开日志文件夹'; Handler = 'Invoke-HvMenuLogFolder' }
        [pscustomobject]@{ Key = '13'; Label = '健康检查'; Handler = 'Invoke-HvMenuDoctor' }
        [pscustomobject]@{ Key = '14'; Label = '更新'; Handler = 'Invoke-HvMenuUpdate' }
        [pscustomobject]@{ Key = '15'; Label = '用户管理'; Handler = 'Invoke-HvMenuUsers' }
        [pscustomobject]@{ Key = '0'; Label = '退出'; Handler = '' }
    )
}

function ConvertTo-HvHalfWidth {
    # Pure: full-width digits/letters typed with a Chinese IME (０-９, Ａ-Ｚ) -> ASCII; ideographic space -> space.
    param([AllowEmptyString()][AllowNull()][string]$Text)
    $sb = New-Object System.Text.StringBuilder
    foreach ($ch in ([string]$Text).ToCharArray()) {
        $c = [int]$ch
        if ($c -ge 0xFF01 -and $c -le 0xFF5E) { [void]$sb.Append([char]($c - 0xFEE0)) }
        elseif ($c -eq 0x3000) { [void]$sb.Append(' ') }
        else { [void]$sb.Append($ch) }
    }
    return $sb.ToString()
}

function ConvertTo-HvMenuChoice {
    # Pure: normalise what was typed at the menu prompt: trim, full-width -> ASCII, "01" -> "1", "3." -> "3",
    # q / quit / exit / 退出 -> "0". Anything else is returned trimmed (and will not match an item).
    param([AllowEmptyString()][AllowNull()][string]$Text)
    $t = (ConvertTo-HvHalfWidth $Text).Trim().TrimEnd('.', '。', '、').Trim()
    if (@('q', 'quit', 'exit', '退出') -contains $t.ToLowerInvariant()) { return '0' }
    if ($t -match '^[0-9]{1,3}$') { return ([string][int]$t) }
    return $t
}

function Resolve-HvMenuItem {
    param([AllowEmptyString()][string]$Choice, [object[]]$Items)
    foreach ($it in @($Items)) { if ($it.Key -eq $Choice) { return $it } }
    return $null
}

function Format-HvMenuLines {
    # Pure: the menu in two columns (first half left, rest incl. 0 right), CJK-width aware.
    param([object[]]$Items, [string[]]$Header = @(), [int]$ColumnWidth = 26)
    $list = @($Items)
    $half = [int][Math]::Ceiling($list.Count / 2)
    $out = New-Object System.Collections.Generic.List[string]
    $bar = '=' * 60
    $out.Add($bar)
    foreach ($h in @($Header)) { $out.Add('  ' + $h) }
    $out.Add($bar)
    for ($i = 0; $i -lt $half; $i++) {
        $left = $list[$i]
        $l = ('{0,4}. ' -f $left.Key) + $left.Label
        $line = '  ' + (Format-HvPad $l $ColumnWidth)
        if ($i + $half -lt $list.Count) {
            $right = $list[$i + $half]
            $line += ('{0,4}. ' -f $right.Key) + $right.Label
        }
        $out.Add($line.TrimEnd())
    }
    $out.Add('-' * 60)
    return $out.ToArray()
}

# ---------------------------------------------------------------- small helpers

function Get-HvMenuHeader {
    $h = @('HomeVault 家庭归档服务器 · 管理菜单')
    if (-not (Test-HvEnvExists)) {
        $h += '尚未安装：请先双击仓库根目录的“一键安装.cmd”。'
        return $h
    }
    try {
        $h += ('访问地址（手机/电脑）：' + (Get-HvCanonicalUrl))
        $h += ('管理面板：' + (Get-HvPanelUrl) + '（用 Nextcloud 管理员账号登录）')
        $h += ('日志保留：' + (Get-HvLogRetentionDays) + ' 天')
    } catch { }
    return $h
}

function Open-HvUrl {
    # explorer.exe opens the URL in the default browser as the signed-in user (not elevated).
    param([string]$Url)
    Write-HvInfo ('地址：' + $Url)
    if (Test-HvWindows) {
        try { Start-Process -FilePath 'explorer.exe' -ArgumentList ('"' + $Url + '"') } catch { Write-HvWarn '无法自动打开浏览器，请手动复制上面的地址。' }
    }
}

function Read-HvMenuPause {
    if (Test-HvInteractive) { [void](Read-Host '按回车键返回菜单') }
}

function Read-HvMenuSub {
    # A numbered sub-menu; returns the chosen key ('0' = back).
    param([string]$Title, [string[]]$Entries)
    Write-Host ''
    Write-Host ('  ' + $Title) -ForegroundColor Cyan
    for ($i = 0; $i -lt $Entries.Count; $i++) { Write-Host ('   ' + ($i + 1) + '. ' + $Entries[$i]) }
    Write-Host '   0. 返回'
    if (-not (Test-HvInteractive)) { return '0' }
    while ($true) {
        $k = ConvertTo-HvMenuChoice (Read-Host '请输入编号')
        if ($k -eq '' -or $k -eq '0') { return '0' }
        $n = 0
        if ([int]::TryParse($k, [ref]$n) -and $n -ge 1 -and $n -le $Entries.Count) { return $k }
        Write-HvWarn '没有这个选项，请重新输入。'
    }
}

# ---------------------------------------------------------------- item handlers (each calls an hv command function)

function Invoke-HvMenuStatus {
    Invoke-HvCmdStatus -Arguments @()
    Write-HvInfo ('管理面板：' + (Get-HvPanelUrl))
    try { Write-HvInfo ('日志目录：' + (Get-HvLogDir) + '（保留 ' + (Get-HvLogRetentionDays) + ' 天）') } catch { }
}

function Invoke-HvMenuUp { Invoke-HvCmdUp -Arguments @('--wait') }

function Invoke-HvMenuDown {
    if (-not (Read-HvYesNo '停止后手机将无法备份、网页也无法访问（数据不受影响）。确定停止？' $false)) { Write-HvInfo '已取消。'; return }
    Invoke-HvCmdDown -Arguments @()
}

function Invoke-HvMenuLogs {
    $k = Read-HvMenuSub -Title '查看日志' -Entries @(
        '列出全部日志文件'
        'Nextcloud 日志（nextcloud.log：错误与警告）'
        '审计日志（audit.log：登录、分享、文件操作）'
        '访问日志（Caddy：每个网页/手机请求）'
        '最近一次备份的日志'
        '今天的 HomeVault 操作日志'
        '容器输出（选择服务）'
    )
    switch ($k) {
        '1' { Invoke-HvLogs -Arguments @('list') }
        '2' { Invoke-HvLogs -Arguments @('show', 'nextcloud') }
        '3' { Invoke-HvLogs -Arguments @('show', 'audit') }
        '4' { Invoke-HvLogs -Arguments @('show', 'access') }
        '5' { Invoke-HvLogs -Arguments @('show', 'backup') }
        '6' { Invoke-HvLogs -Arguments @('show', 'hv') }
        '7' {
            $svc = Read-HvValue -Prompt ('服务名（' + ($script:HvLogServices -join ' / ') + '）') -Default 'app' `
                -Validate { param($v) $script:HvLogServices -contains $v } -ErrorText ('请输入以下之一：' + ($script:HvLogServices -join ' '))
            Invoke-HvLogs -Arguments @('show', $svc, '--lines', '200')
        }
    }
}

function Invoke-HvMenuLogRetention {
    $cur = Get-HvLogRetentionDays
    Write-HvInfo ('当前日志保留天数：' + $cur + ' 天（超过的日志每天 04:00 自动删除）')
    $v = Read-HvValue -Prompt '新的保留天数（1-365，直接回车保持不变）' -Default ([string]$cur) `
        -Validate { param($x) $ok = $true; try { [void](ConvertTo-HvRetentionDays (ConvertTo-HvHalfWidth $x)) } catch { $ok = $false }; $ok } `
        -ErrorText '请输入 1 到 365 之间的整数，例如 7、14、30。'
    $d = ConvertTo-HvRetentionDays (ConvertTo-HvHalfWidth $v)
    if ($d -eq $cur) { Write-HvInfo '保留天数未改变。'; return }
    Invoke-HvLogs -Arguments @('retention', [string]$d)
}

function Get-HvSuggestedPeerName {
    $used = @()
    try { $used = @(Get-HvPeers | ForEach-Object { $_.name }) } catch { }
    for ($i = 1; $i -lt 100; $i++) { if ($used -notcontains ('phone' + $i)) { return ('phone' + $i) } }
    return 'phone'
}

function Invoke-HvMenuVpnAdd {
    Write-HvInfo '为一台手机生成 VPN 配置并显示二维码：用 WG Tunnel（推荐）或 WireGuard App 扫码导入。'
    Write-HvInfo '名称只能用英文字母、数字和 _ = + . -，最长 15 个字符，例如 phone-mama。'
    $name = Read-HvValue -Prompt '设备名称' -Default (Get-HvSuggestedPeerName) -Validate { param($v) Test-HvPeerName $v } `
        -ErrorText '名称只能包含英文字母、数字和 _ = + . -，最长 15 个字符。'
    Invoke-HvCmdVpn -Arguments @('add', $name)
}

function Invoke-HvMenuVpnList { Invoke-HvCmdVpn -Arguments @('list') }

function Invoke-HvMenuBackup {
    if (-not (Read-HvYesNo '现在备份？（导出数据库时 Nextcloud 会短暂进入维护模式，通常不到 1 分钟）' $true)) { Write-HvInfo '已取消。'; return }
    $log = Invoke-HvBackupLogged
    if ($log) { Write-HvInfo ('备份日志：' + $log) }
}

function Invoke-HvMenuBackupHistory {
    $bs = Read-HvStateJson 'backup-status.json'
    if ($null -ne $bs) {
        $state = [string](Get-HvPropValue $bs 'state' '')
        $names = @{ ok = '成功'; partial = '不完整'; failed = '失败'; running = '进行中'; never = '从未备份' }
        if ($names.ContainsKey($state)) { $state = $names[$state] }
        Write-HvInfo ('最近一次备份：' + $state + '，' + (Format-HvLocalTime (Get-HvPropValue $bs 'last_finished' (Get-HvPropValue $bs 'last_run' ''))))
        $msg = [string](Get-HvPropValue $bs 'message' '')
        if ($msg) { Write-HvInfo ('说明：' + $msg) }
    }
    $ok = Join-HvPath (Get-HvStateDir) 'last-backup-ok'
    if ([System.IO.File]::Exists($ok)) { Write-HvInfo ('最近一次成功备份：' + (Read-HvTextFile $ok).Trim()) }
    Write-HvStep '备份仓库中的快照（restic snapshots）'
    Invoke-HvCmdRestore -Arguments @()
}

function Invoke-HvMenuStorage { Invoke-HvCmdStorage -Arguments @('list') }

function Invoke-HvMenuPanel {
    Open-HvUrl (Get-HvPanelUrl)
    Write-HvInfo '用 Nextcloud 管理员账号登录（含两步验证）。手机上也可以安装 HomeVault 安卓 App 直接打开。'
}

function Invoke-HvMenuLogFolder { Invoke-HvLogs -Arguments @('open') }

function Invoke-HvMenuDoctor { Invoke-HvCmdDoctor -Arguments @() }

function Invoke-HvMenuUpdate {
    Write-HvInfo '更新会先备份，再拉取新镜像并重建容器；期间服务中断几分钟。'
    if (-not (Read-HvYesNo '现在更新？' $false)) { Write-HvInfo '已取消。'; return }
    Invoke-HvCmdUpdate -Arguments @()
}

function Invoke-HvMenuUsers {
    $k = Read-HvMenuSub -Title '用户管理（Nextcloud 账号）' -Entries @('用户列表', '添加用户', '重置用户密码', '重置两步验证（手机丢失或换机时）')
    switch ($k) {
        '1' { Invoke-HvCmdUser -Arguments @('list') }
        '2' {
            $name = Read-HvValue -Prompt '用户名（字母、数字和 _ . @ -）' -Validate { param($v) Test-HvUserName $v } -ErrorText '用户名只能用字母、数字和 _ . @ -'
            $a = @('add', $name)
            $dn = Read-HvValue -Prompt '显示名称（可中文，直接回车跳过）' -Default ''
            if ($dn) { $a += @('--display-name', $dn) }
            $q = Read-HvValue -Prompt '空间配额（例如 500GB、1TB；直接回车 = 不限制）' -Default '' `
                -Validate { param($v) if (-not $v) { return $true }; try { [void](ConvertTo-HvQuota $v); return $true } catch { return $false } } -ErrorText '例如 500GB、1TB，或直接回车'
            if ($q) { $a += @('--quota', $q) }
            if (Read-HvYesNo '设为管理员？（可以管理所有用户和设置）' $false) { $a += '--admin' }
            Invoke-HvCmdUser -Arguments $a
        }
        '3' {
            $name = Read-HvValue -Prompt '要重置密码的用户名' -Validate { param($v) Test-HvUserName $v } -ErrorText '请输入用户名'
            Invoke-HvCmdUser -Arguments @('reset-password', $name)
        }
        '4' {
            $name = Read-HvValue -Prompt '要重置两步验证的用户名' -Validate { param($v) Test-HvUserName $v } -ErrorText '请输入用户名'
            Invoke-HvCmdUser -Arguments @('reset-2fa', $name)
        }
    }
}

# ---------------------------------------------------------------- the menu

function Invoke-HvMenu {
    # hv.ps1 menu: loops until 0. Errors of an item are shown and the menu continues.
    param([Parameter(ValueFromRemainingArguments = $true)][object[]]$Arguments = @())
    [void](Read-HvCommandArgs -Arguments $Arguments)
    if (-not (Test-HvInteractive)) { Stop-Hv '管理菜单需要在交互式窗口中运行（双击 windows\HomeVault管理.cmd 或桌面上的“HomeVault 管理”）。' 2 }
    Start-HvUxLog 'menu'
    $items = Get-HvMenuItems
    while ($true) {
        try { Clear-Host } catch { }
        foreach ($l in (Format-HvMenuLines -Items $items -Header (Get-HvMenuHeader))) { Write-Host $l }
        $raw = Read-Host '请输入编号后按回车'
        $key = ConvertTo-HvMenuChoice $raw
        if ($key -eq '') { continue }
        if ($key -eq '0') { break }
        $item = Resolve-HvMenuItem -Choice $key -Items $items
        if ($null -eq $item) {
            Write-Host ('没有这个选项：' + $raw + '（请输入 0-15 的数字）') -ForegroundColor Yellow
            Read-HvMenuPause
            continue
        }
        Write-Host ''
        Write-Host ('======== ' + $item.Key + '. ' + $item.Label + ' ========') -ForegroundColor Cyan
        Write-HvLog ('菜单：' + $item.Key + '. ' + $item.Label)
        try {
            & $item.Handler | Out-Host
        } catch {
            Write-HvErr (Get-HvErrorMessage $_)
        }
        $script:HvYes = $false
        Write-Host ''
        Read-HvMenuPause
    }
    $script:HvExitCode = 0
    Write-Host '已退出 HomeVault 管理菜单。'
}
