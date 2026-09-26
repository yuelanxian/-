# HomeVault Windows CLI - disk inventory (Windows wrappers) + table/warnings/selection helpers (pure).

function Get-HvSystemDriveLetter {
    $sd = [System.Environment]::GetEnvironmentVariable('SystemDrive')
    if ($sd) { return $sd.Substring(0, 1).ToUpperInvariant() }
    return 'C'
}

function Get-HvDiskInventory {
    # One row per lettered volume: letter, label, fs, size, free, physical disk #, media, system, USB, BitLocker.
    if (-not (Test-HvWindows)) { return @() }
    $sys = Get-HvSystemDriveLetter
    $phys = @{}
    foreach ($pd in @(Get-PhysicalDisk -ErrorAction SilentlyContinue)) { $phys[[string]$pd.DeviceId] = $pd }
    $bl = @{}
    if (Get-Command Get-BitLockerVolume -ErrorAction SilentlyContinue) {
        try {
            foreach ($b in @(Get-BitLockerVolume -ErrorAction Stop)) {
                $bl[([string]$b.MountPoint).TrimEnd('\').TrimEnd(':').ToUpperInvariant()] = [string]$b.ProtectionStatus
            }
        } catch { }
    }
    $rows = @()
    foreach ($v in @(Get-Volume -ErrorAction SilentlyContinue | Where-Object { $_.DriveLetter })) {
        $letter = ([string]$v.DriveLetter).ToUpperInvariant()
        $diskNo = ''; $media = '?'; $usb = $false; $isSysDisk = $false; $bus = ''
        try {
            $part = Get-Partition -DriveLetter $letter -ErrorAction Stop | Select-Object -First 1
            $diskNo = [string]$part.DiskNumber
            $disk = Get-Disk -Number $part.DiskNumber -ErrorAction Stop
            $bus = [string]$disk.BusType
            $usb = ($bus -eq 'USB')
            $isSysDisk = [bool]($disk.IsSystem -or $disk.IsBoot)
            if ($phys.ContainsKey($diskNo)) {
                $mt = [string]$phys[$diskNo].MediaType
                if ($mt -eq 'SSD' -or $mt -eq 'SCM') { $media = 'SSD' } elseif ($mt -eq 'HDD') { $media = 'HDD' }
                if ([string]$phys[$diskNo].BusType -eq 'USB') { $usb = $true }
            }
        } catch { }
        $fs = [string]$v.FileSystemType
        if (-not $fs) { $fs = [string]$v.FileSystem }
        $blState = '-'
        if ($bl.ContainsKey($letter)) { $blState = $bl[$letter] }
        $rows += [pscustomobject]@{
            Letter     = $letter
            Label      = [string]$v.FileSystemLabel
            FileSystem = $fs
            SizeBytes  = [double]$v.Size
            FreeBytes  = [double]$v.SizeRemaining
            DiskNumber = $diskNo
            Media      = $media
            IsSystem   = ($letter -eq $sys)
            IsSysDisk  = $isSysDisk
            IsUsb      = $usb
            DriveType  = [string]$v.DriveType
            BitLocker  = $blState
            BusType    = $bus
        }
    }
    return @($rows | Sort-Object Letter)
}

function Format-HvDiskTable {
    param([object[]]$Disks)
    $view = @()
    foreach ($d in @($Disks)) {
        $sysText = '否'; if ($d.IsSystem) { $sysText = '是' }
        $usbText = '否'; if ($d.IsUsb) { $usbText = '是' }
        $label = $d.Label; if (-not $label) { $label = '-' }
        $view += [pscustomobject]@{
            L = ($d.Letter + ':'); Label = $label; Fs = $d.FileSystem; Size = (ConvertTo-HvSizeText $d.SizeBytes); Free = (ConvertTo-HvSizeText $d.FreeBytes)
            Disk = $d.DiskNumber; Media = $d.Media; Sys = $sysText; Usb = $usbText; Bl = $d.BitLocker
        }
    }
    return (Format-HvTable -Rows $view -Columns @('L', 'Label', 'Fs', 'Size', 'Free', 'Disk', 'Media', 'Sys', 'Usb', 'Bl') `
            -Headers @('盘符', '卷标', '文件系统', '总容量', '可用', '物理磁盘#', 'SSD/HDD', '系统盘', 'USB', 'BitLocker'))
}

function Find-HvDisk {
    param([object[]]$Disks, [string]$Letter)
    $l = ([string]$Letter).Trim().TrimEnd('\').TrimEnd(':').ToUpperInvariant()
    foreach ($d in @($Disks)) { if ($d.Letter -eq $l) { return $d } }
    return $null
}

function Get-HvDriveLetterFromPath {
    param([string]$Path)
    if ($Path -match '^([A-Za-z]):') { return $Matches[1].ToUpperInvariant() }
    return ''
}

function Test-HvWindowsAbsPath {
    param([AllowEmptyString()][string]$Path)
    return ($Path -match '^[A-Za-z]:\\')
}

function Get-HvDiskWarnings {
    # Pure: Chinese warnings for a disk used in a role (primary / storage / backup).
    param($Disk, [string]$Role = 'primary')
    $w = @()
    if ($null -eq $Disk) { return $w }
    $fs = ([string]$Disk.FileSystem).ToUpperInvariant()
    if ($fs -eq 'FAT32' -or $fs -eq 'FAT') { $w += ($Disk.Letter + ': 是 FAT32：单个文件不能超过 4 GB（手机视频会失败），且没有权限控制，强烈建议改用 NTFS。') }
    elseif ($fs -eq 'EXFAT') { $w += ($Disk.Letter + ': 是 exFAT：没有权限控制和日志，断电易损坏，建议改用 NTFS。') }
    if ($Role -eq 'primary') {
        if ($Disk.IsSystem) { $w += ($Disk.Letter + ': 是系统盘：重装系统或系统盘故障会同时威胁数据，建议选择单独的数据盘。') }
        if ($Disk.IsUsb) { $w += ($Disk.Letter + ': 是 USB 外置盘：断开或盘符变化会导致 Nextcloud 无法启动，不建议作为主数据盘。') }
    }
    if ($Role -eq 'backup' -and $Disk.IsSystem) { $w += ($Disk.Letter + ': 是系统盘：备份放在系统盘上意义有限。') }
    return $w
}

function Test-HvSamePhysicalDisk {
    param($A, $B)
    if ($null -eq $A -or $null -eq $B) { return $false }
    if (-not $A.DiskNumber -or -not $B.DiskNumber) { return ($A.Letter -eq $B.Letter) }
    return ($A.DiskNumber -eq $B.DiskNumber)
}

function Get-HvDefaultDataDisk {
    # Pure: largest-free fixed NTFS/ReFS non-system non-USB volume; falls back to the system drive.
    param([object[]]$Disks)
    $best = $null
    foreach ($d in @($Disks)) {
        if ($d.IsSystem -or $d.IsUsb) { continue }
        if (@('NTFS', 'REFS') -notcontains ([string]$d.FileSystem).ToUpperInvariant()) { continue }
        if ($null -eq $best -or $d.FreeBytes -gt $best.FreeBytes) { $best = $d }
    }
    if ($null -eq $best) { foreach ($d in @($Disks)) { if ($d.IsSystem) { $best = $d } } }
    return $best
}

function Get-HvBackupDiskWarnings {
    # Pure: strong warnings when the backup target shares a physical disk with data.
    param($BackupDisk, $PrimaryDisk, [object[]]$RwStorageDisks = @())
    $w = @()
    if ($null -eq $BackupDisk) { return $w }
    if (Test-HvSamePhysicalDisk $BackupDisk $PrimaryDisk) {
        $w += ('备份目标 ' + $BackupDisk.Letter + ': 与主数据盘 ' + $PrimaryDisk.Letter + ': 在同一块物理磁盘上：这块硬盘损坏时数据和备份会一起丢失！请换一块硬盘（例如 USB 移动硬盘）或使用 S3 异地备份。')
    }
    foreach ($s in @($RwStorageDisks)) {
        if ($null -ne $s -and (Test-HvSamePhysicalDisk $BackupDisk $s) -and -not (Test-HvSamePhysicalDisk $s $PrimaryDisk)) {
            $w += ('备份目标 ' + $BackupDisk.Letter + ': 与可写存储所在的 ' + $s.Letter + ': 在同一块物理磁盘上：这块硬盘损坏时存储和备份会一起丢失。')
        }
    }
    return $w
}
