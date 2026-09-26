# HomeVault Windows CLI - multi-disk storage: storage.conf, compose.storage.yaml, files_external sync.

$script:HvMountPrefix = '/mnt/hv/'

function Get-HvStorageSlug {
    # 's' + first 8 hex chars of SHA-256 over the UTF-8 bytes of the host path as written (same as the bash CLI).
    param([Parameter(Mandatory = $true)][string]$Path)
    return ('s' + (Get-HvSha256Hex $Path).Substring(0, 8))
}

function Get-HvStorageConfHeader {
    return (@(
            '# HomeVault 额外存储（多硬盘）配置。修改后运行 .\windows\hv.ps1 storage apply 生效。'
            '# 每行一个存储，字段用 | 分隔；以 # 开头的行是注释。'
            '# 名称|主机路径|rw或ro|是否备份(yes/no)|可见用户(空=所有用户; 逗号分隔; @开头为群组)'
            '# 示例：'
            '# 照片归档|D:\Photos|rw|no|'
            '# 影视资料|E:\Movies|ro|no|@family'
        ) -join "`n") + "`n"
}

function Test-HvStorageName {
    param([AllowEmptyString()][string]$Name)
    if ([string]::IsNullOrWhiteSpace($Name)) { return $false }
    if ($Name.Length -gt 64) { return $false }
    if ($Name -match '[\\/|:*?"<>]') { return $false }
    if ($Name -eq '.' -or $Name -eq '..') { return $false }
    return $true
}

function ConvertFrom-HvStorageConf {
    # Pure parser; throws a Chinese message with the line number on invalid input.
    param([AllowEmptyString()][string]$Text)
    $rows = New-Object System.Collections.Generic.List[object]
    $names = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    $slugs = @{}
    $lineNo = 0
    foreach ($line in ($Text -split "`r?`n")) {
        $lineNo++
        $t = $line.Trim()
        if ($t -eq '' -or $t.StartsWith('#')) { continue }
        $f = @($t -split '\|')
        if ($f.Count -lt 4 -or $f.Count -gt 5) {
            throw ('storage.conf 第 ' + $lineNo + ' 行格式错误（应为 名称|主机路径|rw或ro|是否备份|可见用户）：' + $t)
        }
        $name = $f[0].Trim(); $path = $f[1].Trim(); $mode = $f[2].Trim().ToLowerInvariant(); $backup = $f[3].Trim().ToLowerInvariant()
        $users = ''
        if ($f.Count -eq 5) { $users = $f[4].Trim() }
        if (-not (Test-HvStorageName $name)) { throw ('storage.conf 第 ' + $lineNo + ' 行：名称无效（不能为空，不能包含 \ / | : * ? " < >）：' + $name) }
        if ($path -eq '') { throw ('storage.conf 第 ' + $lineNo + ' 行：主机路径为空') }
        if (@('rw', 'ro') -notcontains $mode) { throw ('storage.conf 第 ' + $lineNo + ' 行：第 3 列必须是 rw 或 ro：' + $mode) }
        if (@('yes', 'no') -notcontains $backup) { throw ('storage.conf 第 ' + $lineNo + ' 行：第 4 列必须是 yes 或 no：' + $backup) }
        if (-not $names.Add($name)) { throw ('storage.conf 第 ' + $lineNo + ' 行：名称重复：' + $name) }
        $slug = Get-HvStorageSlug $path
        if ($slugs.ContainsKey($slug)) { throw ('storage.conf 第 ' + $lineNo + ' 行：路径与第 ' + $slugs[$slug] + ' 行重复：' + $path) }
        $slugs[$slug] = $lineNo
        $userList = @(); $groupList = @()
        foreach ($u in ($users -split ',')) {
            $x = $u.Trim()
            if ($x -eq '') { continue }
            if ($x.StartsWith('@')) {
                $g = $x.Substring(1).Trim()
                if ($g -eq '') { throw ('storage.conf 第 ' + $lineNo + ' 行：群组名为空') }
                $groupList += $g
            } else { $userList += $x }
        }
        $rows.Add([pscustomobject]@{
                Name      = $name
                Path      = $path
                Mode      = $mode
                ReadOnly  = ($mode -eq 'ro')
                Backup    = ($backup -eq 'yes')
                Users     = $users
                UserList  = $userList
                GroupList = $groupList
                Slug      = $slug
                Line      = $lineNo
            })
    }
    return $rows.ToArray()
}

function ConvertTo-HvStorageConfLine {
    param([string]$Name, [string]$Path, [string]$Mode = 'rw', [string]$Backup = 'no', [string]$Users = '')
    return ($Name + '|' + $Path + '|' + $Mode + '|' + $Backup + '|' + $Users)
}

function Add-HvStorageConfLine {
    # Pure: append a row (validates the whole result).
    param([AllowEmptyString()][string]$Text, [string]$Line)
    $t = $Text
    if ([string]::IsNullOrWhiteSpace($t)) { $t = Get-HvStorageConfHeader }
    if (-not $t.EndsWith("`n")) { $t += "`n" }
    $t += ($Line + "`n")
    [void](ConvertFrom-HvStorageConf $t)
    return $t
}

function Remove-HvStorageConfLine {
    # Pure: drop the row with this name, keep comments and other rows untouched.
    param([AllowEmptyString()][string]$Text, [string]$Name)
    $out = @(); $found = $false
    foreach ($line in (Split-HvLines $Text)) {
        $t = $line.Trim()
        if ($t -ne '' -and -not $t.StartsWith('#')) {
            $n = ($t -split '\|')[0].Trim()
            if ($n -eq $Name) { $found = $true; continue }
        }
        $out += $line
    }
    if (-not $found) { throw ('storage.conf 中没有名为“' + $Name + '”的存储。') }
    return (($out -join "`n") + "`n")
}

function ConvertTo-HvYamlSingleQuoted {
    param([AllowEmptyString()][string]$Text)
    return ("'" + ($Text -replace "'", "''") + "'")
}

function ConvertTo-HvComposeStorageYaml {
    # Pure: compose overlay adding external storages to app/cron (rw/ro) and backup (ro, backup=yes only).
    param([object[]]$Rows = @())
    $rows2 = @($Rows)
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append("# 由 HomeVault 自动生成（storage apply），请勿手工编辑；请修改 storage.conf 后运行 storage apply。`n")
    if ($rows2.Count -eq 0) {
        [void]$sb.Append("services: {}`n")
        return $sb.ToString()
    }
    $mountBlock = New-Object System.Text.StringBuilder
    foreach ($r in $rows2) {
        $ro = 'false'
        if ($r.ReadOnly) { $ro = 'true' }
        [void]$mountBlock.Append('      # ' + ($r.Name -replace "[`r`n]", ' ') + ' (' + $r.Mode + ")`n")
        [void]$mountBlock.Append("      - type: bind`n")
        [void]$mountBlock.Append('        source: ' + (ConvertTo-HvYamlSingleQuoted $r.Path) + "`n")
        [void]$mountBlock.Append('        target: ' + $script:HvMountPrefix + $r.Slug + "`n")
        [void]$mountBlock.Append('        read_only: ' + $ro + "`n")
        [void]$mountBlock.Append("        bind:`n")
        [void]$mountBlock.Append("          create_host_path: false`n")
    }
    [void]$sb.Append("services:`n")
    foreach ($svc in @('app', 'cron')) {
        [void]$sb.Append('  ' + $svc + ":`n")
        [void]$sb.Append("    volumes:`n")
        [void]$sb.Append($mountBlock.ToString())
    }
    $backupRows = @($rows2 | Where-Object { $_.Backup })
    if ($backupRows.Count -gt 0) {
        [void]$sb.Append("  backup:`n")
        [void]$sb.Append("    volumes:`n")
        foreach ($r in $backupRows) {
            [void]$sb.Append('      # ' + ($r.Name -replace "[`r`n]", ' ') + "`n")
            [void]$sb.Append("      - type: bind`n")
            [void]$sb.Append('        source: ' + (ConvertTo-HvYamlSingleQuoted $r.Path) + "`n")
            [void]$sb.Append('        target: /src/storage/' + $r.Slug + "`n")
            [void]$sb.Append("        read_only: true`n")
            [void]$sb.Append("        bind:`n")
            [void]$sb.Append("          create_host_path: false`n")
        }
    }
    return $sb.ToString()
}

# ---------------------------------------------------------------- files_external sync (pure planning)

function ConvertFrom-HvMountListJson {
    # Parse `occ files_external:list --output=json`.
    param([AllowEmptyString()][string]$Json)
    $slice = Get-HvJsonSlice $Json
    $list = New-Object System.Collections.Generic.List[object]
    if (-not $slice -or -not $slice.StartsWith('[')) { return $list.ToArray() }
    $parsed = ConvertFrom-Json -InputObject $slice
    foreach ($m in $parsed) {
        if ($null -eq $m) { continue }
        $cfg = Get-HvPropValue $m 'configuration'
        $opt = Get-HvPropValue $m 'options'
        $datadir = ''
        if ($cfg -and -not ($cfg -is [System.Array])) { $datadir = [string](Get-HvPropValue $cfg 'datadir' '') }
        $readonly = $false; $check = ''
        if ($opt -and -not ($opt -is [System.Array])) {
            $readonly = Test-HvTrue (Get-HvPropValue $opt 'readonly' $false)
            $cv = Get-HvPropValue $opt 'filesystem_check_changes' $null
            if ($null -ne $cv) { $check = [string]$cv }
        }
        $users = @(@(Get-HvPropValue $m 'applicable_users' @()) | Where-Object { $_ } | ForEach-Object { [string]$_ })
        $groups = @(@(Get-HvPropValue $m 'applicable_groups' @()) | Where-Object { $_ } | ForEach-Object { [string]$_ })
        $list.Add([pscustomobject]@{
                Id           = [int](Get-HvPropValue $m 'mount_id' 0)
                MountPoint   = [string](Get-HvPropValue $m 'mount_point' '')
                Storage      = [string](Get-HvPropValue $m 'storage' '')
                DataDir      = $datadir
                ReadOnly     = $readonly
                CheckChanges = $check
                Users        = $users
                Groups       = $groups
            })
    }
    return $list.ToArray()
}

function Get-HvListDiff {
    # Case-sensitive set difference helper: items in A not in B.
    param([string[]]$A = @(), [string[]]$B = @())
    $set = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::Ordinal)
    foreach ($x in @($B)) { if ($null -ne $x) { [void]$set.Add([string]$x) } }
    $out = @()
    foreach ($x in @($A)) { if ($null -ne $x -and -not $set.Contains([string]$x)) { $out += [string]$x } }
    return $out
}

function Get-HvMountUpdate {
    # Pure: occ changes needed so an existing mount matches the storage.conf row.
    param($Row, $Current)
    $opts = [ordered]@{}
    if ([bool]$Current.ReadOnly -ne [bool]$Row.ReadOnly) { if ($Row.ReadOnly) { $opts['readonly'] = 'true' } else { $opts['readonly'] = 'false' } }
    if ([string]$Current.CheckChanges -ne '1') { $opts['filesystem_check_changes'] = '1' }
    $wantUsers = @($Row.UserList); $wantGroups = @($Row.GroupList)
    $haveUsers = @($Current.Users); $haveGroups = @($Current.Groups)
    $removeAll = $false
    $addU = @(); $remU = @(); $addG = @(); $remG = @()
    if ($wantUsers.Count -eq 0 -and $wantGroups.Count -eq 0) {
        if ($haveUsers.Count -gt 0 -or $haveGroups.Count -gt 0) { $removeAll = $true }
    } else {
        $addU = @(Get-HvListDiff $wantUsers $haveUsers); $remU = @(Get-HvListDiff $haveUsers $wantUsers)
        $addG = @(Get-HvListDiff $wantGroups $haveGroups); $remG = @(Get-HvListDiff $haveGroups $wantGroups)
    }
    $changed = ($opts.Count -gt 0) -or $removeAll -or ($addU.Count + $remU.Count + $addG.Count + $remG.Count -gt 0)
    return [pscustomobject]@{
        Type = 'update'; Id = $Current.Id; Name = $Row.Name; Options = $opts; RemoveAll = $removeAll
        AddUsers = $addU; RemoveUsers = $remU; AddGroups = $addG; RemoveGroups = $remG; Changed = $changed
    }
}

function Get-HvMountPlan {
    # Pure: list of create/delete/update actions. Only mounts whose datadir is under /mnt/hv/ are managed.
    param([object[]]$Desired = @(), [object[]]$Current = @())
    $actions = New-Object System.Collections.Generic.List[object]
    $managed = @{}
    foreach ($c in @($Current)) {
        if ($c.DataDir -and $c.DataDir.StartsWith($script:HvMountPrefix)) {
            if ($managed.ContainsKey($c.DataDir)) {
                $actions.Add([pscustomobject]@{ Type = 'delete'; Id = $c.Id; Name = $c.MountPoint; Reason = '重复的挂载' })
            } else { $managed[$c.DataDir] = $c }
        }
    }
    $wanted = @{}
    foreach ($r in @($Desired)) {
        $dir = $script:HvMountPrefix + $r.Slug
        $wanted[$dir] = $true
        $mp = '/' + $r.Name
        if ($managed.ContainsKey($dir)) {
            $c = $managed[$dir]
            if ($c.MountPoint -cne $mp) {
                $actions.Add([pscustomobject]@{ Type = 'delete'; Id = $c.Id; Name = $c.MountPoint; Reason = '名称已改为 ' + $r.Name })
                $actions.Add([pscustomobject]@{ Type = 'create'; Row = $r; Name = $r.Name })
            } else {
                $u = Get-HvMountUpdate -Row $r -Current $c
                if ($u.Changed) { $actions.Add($u) }
            }
        } else {
            $actions.Add([pscustomobject]@{ Type = 'create'; Row = $r; Name = $r.Name })
        }
    }
    foreach ($dir in @($managed.Keys)) {
        if (-not $wanted.ContainsKey($dir)) {
            $c = $managed[$dir]
            $actions.Add([pscustomobject]@{ Type = 'delete'; Id = $c.Id; Name = $c.MountPoint; Reason = '已从 storage.conf 删除' })
        }
    }
    return $actions.ToArray()
}

function Get-HvMountCreateArgs {
    param($Row)
    $a = @('files_external:create', ('/' + $Row.Name), 'local', 'null::null', '-c', ('datadir=' + $script:HvMountPrefix + $Row.Slug))
    foreach ($u in @($Row.UserList)) { $a += @('--applicable-user', $u) }
    foreach ($g in @($Row.GroupList)) { $a += @('--applicable-group', $g) }
    return $a
}

function Get-HvMountApplicableArgs {
    param($Update)
    if ($Update.RemoveAll) { return @('files_external:applicable', [string]$Update.Id, '--remove-all') }
    $a = @('files_external:applicable', [string]$Update.Id)
    foreach ($u in @($Update.AddUsers)) { $a += @('--add-user', $u) }
    foreach ($u in @($Update.RemoveUsers)) { $a += @('--remove-user', $u) }
    foreach ($g in @($Update.AddGroups)) { $a += @('--add-group', $g) }
    foreach ($g in @($Update.RemoveGroups)) { $a += @('--remove-group', $g) }
    if ($a.Count -eq 2) { return @() }
    return $a
}

# ---------------------------------------------------------------- runtime

function Get-HvStorageConfPath { return (Get-HvPath 'storage.conf') }

function Read-HvStorageConfText {
    $p = Get-HvStorageConfPath
    if (-not [System.IO.File]::Exists($p)) { return '' }
    return (Read-HvTextFile $p)
}

function Get-HvStorageRows {
    try { return @(ConvertFrom-HvStorageConf (Read-HvStorageConfText)) } catch { Stop-Hv $_.Exception.Message }
}

function Test-HvStoragePathUsable {
    # Returns a list of problems for a Windows host path (empty list = ok).
    param([string]$Path, [string]$NcDataPath = '')
    $p = @()
    if (-not (Test-HvWindowsAbsPath $Path)) { $p += '必须是完整的 Windows 路径，例如 D:\Photos'; return $p }
    if (-not [System.IO.Directory]::Exists($Path)) { $p += ('目录不存在：' + $Path) }
    $norm = $Path.TrimEnd('\') + '\'
    if ($NcDataPath) {
        $nc = $NcDataPath.TrimEnd('\') + '\'
        if ($norm.StartsWith($nc, [System.StringComparison]::OrdinalIgnoreCase) -or $nc.StartsWith($norm, [System.StringComparison]::OrdinalIgnoreCase)) {
            $p += '不能位于 Nextcloud 主数据目录内部，也不能包含它'
        }
    }
    if ($norm -match '^[A-Za-z]:\\$') { $p += '不建议直接挂载整个盘的根目录，请指定一个文件夹' }
    return $p
}

function Write-HvComposeStorageFile {
    # Regenerate compose.storage.yaml from storage.conf; returns $true when the content changed.
    $rows = Get-HvStorageRows
    $yaml = ConvertTo-HvComposeStorageYaml -Rows $rows
    $p = Get-HvPath 'compose.storage.yaml'
    $old = ''
    if ([System.IO.File]::Exists($p)) { $old = Read-HvTextFile $p }
    if ($old -ne $yaml) { Write-HvTextFile -Path $p -Content $yaml; return $true }
    return $false
}

function Invoke-HvStorageSync {
    # Apply the occ plan (app must be running).
    $rows = Get-HvStorageRows
    [void](Invoke-HvOcc -OccArgs @('app:enable', 'files_external') -Capture)
    $r = Invoke-HvOcc -OccArgs @('files_external:list', '--output=json') -Capture
    $current = @(ConvertFrom-HvMountListJson $r.Text)
    $plan = @(Get-HvMountPlan -Desired $rows -Current $current)
    if ($plan.Count -eq 0) { Write-HvOk 'Nextcloud 外部存储挂载已是最新。'; return }
    foreach ($a in $plan) {
        if ($a.Type -eq 'delete') {
            Write-HvInfo ('删除挂载 ' + $a.Name + '（' + $a.Reason + '）')
            [void](Invoke-HvOcc -OccArgs @('files_external:delete', '-y', [string]$a.Id) -Capture)
        } elseif ($a.Type -eq 'create') {
            Write-HvInfo ('创建挂载 /' + $a.Row.Name)
            $cr = Invoke-HvOcc -OccArgs (Get-HvMountCreateArgs $a.Row) -Capture
            $m = [regex]::Match($cr.Text, 'id\s+(\d+)')
            if (-not $m.Success) { Stop-Hv ('创建外部存储失败：' + $cr.Text) }
            $id = $m.Groups[1].Value
            $ro = 'false'; if ($a.Row.ReadOnly) { $ro = 'true' }
            [void](Invoke-HvOcc -OccArgs @('files_external:option', $id, 'readonly', $ro) -Capture)
            [void](Invoke-HvOcc -OccArgs @('files_external:option', $id, 'filesystem_check_changes', '1') -Capture)
        } else {
            Write-HvInfo ('更新挂载 /' + $a.Name)
            foreach ($k in $a.Options.Keys) { [void](Invoke-HvOcc -OccArgs @('files_external:option', [string]$a.Id, [string]$k, [string]$a.Options[$k]) -Capture) }
            $appArgs = @(Get-HvMountApplicableArgs $a)
            if ($appArgs.Count -gt 0) { [void](Invoke-HvOcc -OccArgs $appArgs -Capture) }
        }
    }
    Write-HvOk ('外部存储已同步（' + $plan.Count + ' 项变更）。')
    Write-HvInfo '如果目录里已有文件，请运行：.\windows\hv.ps1 occ files:scan --all（文件多时耗时较长）'
}

function Invoke-HvStorageApply {
    param([switch]$NoSync)
    $changed = Write-HvComposeStorageFile
    if ($changed) { Write-HvOk 'compose.storage.yaml 已更新。' } else { Write-HvInfo 'compose.storage.yaml 无变化。' }
    if ($NoSync) { return }
    $running = Test-HvAppRunning
    if ($changed -and $running) {
        Write-HvStep '重建 app / cron 容器以挂载新的存储...'
        [void](Invoke-HvCompose -Arguments @('up', '-d', '--remove-orphans'))
        [void](Wait-HvHealthy -TimeoutSec 600)
    }
    if (-not $running -and -not $changed) {
        Write-HvWarn '服务未运行：挂载配置将在启动后通过 storage apply 同步。'
        return
    }
    if (-not $running) {
        Write-HvWarn '服务未运行：请先运行 .\windows\hv.ps1 up，然后再运行 storage apply 同步挂载。'
        return
    }
    Invoke-HvStorageSync
}

function Show-HvStorageList {
    $envv = Get-HvEnv
    if (Test-HvWindows) {
        Write-HvStep '本机磁盘'
        foreach ($l in (Format-HvDiskTable (Get-HvDiskInventory))) { Write-Host ('  ' + $l) }
    }
    Write-HvStep '主数据目录'
    Write-HvInfo (Get-HvEnvDictValue $envv 'HV_NC_DATA_PATH' '（未设置）')
    Write-HvStep '额外存储（storage.conf）'
    $rows = @(Get-HvStorageRows)
    if ($rows.Count -eq 0) { Write-HvInfo '（无）可用 storage add 添加。'; return }
    $view = @()
    foreach ($r in $rows) {
        $bk = '否'; if ($r.Backup) { $bk = '是' }
        $u = $r.Users; if (-not $u) { $u = '所有用户' }
        $ok = '存在'
        if ((Test-HvWindows) -and -not [System.IO.Directory]::Exists($r.Path)) { $ok = '不存在!' }
        $view += [pscustomobject]@{ N = $r.Name; P = $r.Path; M = $r.Mode; B = $bk; U = $u; S = $r.Slug; E = $ok }
    }
    foreach ($l in (Format-HvTable -Rows $view -Columns @('N', 'P', 'M', 'B', 'U', 'S', 'E') -Headers @('名称', '主机路径', '读写', '备份', '可见用户', '容器内目录', '状态'))) { Write-Host ('  ' + $l) }
    Write-HvInfo ('容器内路径：/mnt/hv/<容器内目录>；Nextcloud 中显示为同名文件夹。')
}

function Add-HvStorage {
    # Validate and append one storage row (does not apply).
    param([string]$Name, [string]$Path, [string]$Mode = 'rw', [string]$Backup = 'no', [string]$Users = '')
    if (-not (Test-HvStorageName $Name)) { Stop-Hv ('存储名称无效：' + $Name) }
    $mode2 = $Mode.ToLowerInvariant(); $bk = $Backup.ToLowerInvariant()
    if (@('rw', 'ro') -notcontains $mode2) { Stop-Hv '--mode 必须是 rw 或 ro' }
    if (@('yes', 'no') -notcontains $bk) { Stop-Hv '--backup 必须是 yes 或 no' }
    $Path = $Path.Trim()
    if ($Path.Length -gt 3) { $Path = $Path.TrimEnd('\') }
    if (Test-HvWindows) {
        $problems = @(Test-HvStoragePathUsable -Path $Path -NcDataPath (Get-HvEnvValue 'HV_NC_DATA_PATH'))
        foreach ($pr in $problems) { Write-HvWarn $pr }
        if ($problems.Count -gt 0) {
            if (-not [System.IO.Directory]::Exists($Path) -and (Test-HvWindowsAbsPath $Path) -and (Read-HvYesNo ('目录不存在，是否创建 ' + $Path + '？') $false)) {
                [void](New-HvDirectory $Path)
            } elseif (-not (Read-HvYesNo '仍然继续？' $false)) { Stop-Hv '已取消。' }
        }
        $disk = Find-HvDisk (Get-HvDiskInventory) (Get-HvDriveLetterFromPath $Path)
        foreach ($w in (Get-HvDiskWarnings -Disk $disk -Role 'storage')) { Write-HvWarn $w }
    }
    $line = ConvertTo-HvStorageConfLine -Name $Name -Path $Path -Mode $mode2 -Backup $bk -Users $Users
    try { $text = Add-HvStorageConfLine -Text (Read-HvStorageConfText) -Line $line } catch { Stop-Hv $_.Exception.Message }
    Write-HvTextFile -Path (Get-HvStorageConfPath) -Content $text
    Write-HvOk ('已添加存储：' + $line)
}

function Invoke-HvCmdStorage {
    param([object[]]$Arguments = @())
    $p = Read-HvCommandArgs -Arguments $Arguments -Options @('name', 'path', 'mode', 'backup', 'users') -Switches @('no-apply')
    $sub = ''
    if ($p.Positional.Count -gt 0) { $sub = $p.Positional[0] }
    [void](Get-HvEnv)
    switch ($sub) {
        'list' { Show-HvStorageList }
        '' { Show-HvStorageList }
        'add' {
            $name = Get-HvOpt $p 'name' ''
            $path = Get-HvOpt $p 'path' ''
            if (-not $name -and $p.Positional.Count -gt 1) { $name = $p.Positional[1] }
            if (-not $path -and $p.Positional.Count -gt 2) { $path = $p.Positional[2] }
            if (Test-HvWindows) {
                Write-HvStep '本机磁盘'
                foreach ($l in (Format-HvDiskTable (Get-HvDiskInventory))) { Write-Host ('  ' + $l) }
            }
            if (-not $path) { $path = Read-HvValue -Prompt '主机上的文件夹路径（例如 E:\Photos）' -Validate { param($v) Test-HvWindowsAbsPath $v } -ErrorText '请输入完整路径，例如 E:\Photos' }
            if (-not $name) { $name = Read-HvValue -Prompt '在 Nextcloud 中显示的名称' -Default (Split-Path -Leaf $path.TrimEnd('\')) -Validate { param($v) Test-HvStorageName $v } }
            $mode = Get-HvOpt $p 'mode' ''
            if (-not $mode) { $mode = 'rw'; if (-not (Read-HvYesNo '允许通过 Nextcloud 修改/删除其中的文件（读写）？选 n 为只读' $true)) { $mode = 'ro' } }
            $backup = Get-HvOpt $p 'backup' ''
            if (-not $backup) { $backup = 'no'; if (Read-HvYesNo '是否把它包含在 restic 备份中？' $false) { $backup = 'yes' } }
            $users = Get-HvOpt $p 'users' $null
            if ($null -eq $users) { $users = Read-HvValue -Prompt '可见用户（留空=所有用户；逗号分隔；@开头为群组）' -Default '' }
            Add-HvStorage -Name $name -Path $path -Mode $mode -Backup $backup -Users $users
            if (-not (Test-HvOpt $p 'no-apply')) { Invoke-HvStorageApply }
            return
        }
        'remove' {
            $name = Get-HvOpt $p 'name' ''
            if (-not $name -and $p.Positional.Count -gt 1) { $name = $p.Positional[1] }
            if (-not $name) { Stop-Hv '用法：storage remove <名称>' 2 }
            if (-not (Read-HvYesNo ('从 HomeVault 移除存储“' + $name + '”？（不会删除硬盘上的文件，但 Nextcloud 中的共享/标签会失效）') $true)) { Stop-Hv '已取消。' }
            try { $text = Remove-HvStorageConfLine -Text (Read-HvStorageConfText) -Name $name } catch { Stop-Hv $_.Exception.Message }
            Write-HvTextFile -Path (Get-HvStorageConfPath) -Content $text
            Write-HvOk ('已从 storage.conf 移除：' + $name)
            if (-not (Test-HvOpt $p 'no-apply')) { Invoke-HvStorageApply }
            return
        }
        'apply' { Invoke-HvStorageApply }
        default { Stop-Hv ('未知的 storage 子命令：' + $sub + '（可用：list | add | remove <名称> | apply）') 2 }
    }
}
