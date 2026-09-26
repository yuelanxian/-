# 03 · Windows 部署（Windows 10/11 + Docker Desktop）

本文带你在一台 Windows 电脑上部署 HomeVault。Windows 版的功能和 Linux 版相同，但 Windows 本身有一些限制（开机必须有人登录、NTFS 的特性等），所以步骤会多一些。请按顺序阅读。

相关文档：[docs/01-架构与安全.md](01-架构与安全.md) · [docs/02-Linux部署.md](02-Linux部署.md) · [docs/04-VPN与DDNS.md](04-VPN与DDNS.md) · [docs/05-安卓手机备份.md](05-安卓手机备份.md) · [docs/08-日常运维与升级.md](08-日常运维与升级.md)

> 约定：本文的 HomeVault 命令都在 HomeVault 目录里，用**管理员身份**打开 PowerShell 执行，写法是 `.\windows\hv.ps1 <命令>`。`.\windows\hv.ps1 help` 可以列出全部命令。

---

## 0. 先想清楚：Windows 版和 Linux 版的区别

| 方面 | Linux 版 | Windows 版 |
|---|---|---|
| VPN 服务端 | wg-easy 容器（带网页管理界面） | **WireGuard for Windows** 隧道服务，用 `.\windows\hv.ps1 vpn` 管理。wg-easy 在 Docker Desktop 上无法可靠运行，所以不用它 |
| 开机后无人登录时 | 所有服务照常运行 | WireGuard 服务照常运行，但 **Docker Desktop 必须有用户登录后才会启动**。所以要配置"自动登录 + 立即锁屏" |
| Nextcloud 数据目录 | Linux 文件系统（ext4/btrfs） | NTFS 文件夹，可以直接在资源管理器里看到，但速度较慢，而且**不区分大小写**（见 §9） |
| 数据库等程序数据 | 主机目录 | Docker Desktop 虚拟磁盘里的命名卷 |
| 硬盘健康监控 | Scrutiny | CrystalDiskInfo 等 Windows 工具 |

**什么时候选 Windows 版：** 这台电脑平时还要当 Windows 用，或者你暂时不想接触 Linux。
**更稳的替代方案：** Windows 专业版可以用 Hyper-V 虚拟机运行 Linux 版，见 [§12](#12-替代方案hyper-v-虚拟机--linux-套件仅专业版)。

---

## 1. 系统要求

| 项目 | 要求 |
|---|---|
| 操作系统 | **推荐 Windows 11**（23H2 或更新）。Windows 10 需要 22H2（19045） |
| ⚠️ Windows 10 支持期 | Windows 10 已于 2025-10-14 结束支持，面向个人用户的扩展安全更新（ESU）将于 **2026-10-13** 结束。Docker 只支持仍在微软服务期内的 Windows 版本，新部署请用 Windows 11 |
| 版本（家庭版/专业版） | 家庭版、专业版都可以用 WSL2 运行 Linux 容器。完整的 BitLocker 和 Hyper-V 只有专业版、企业版、教育版才有 |
| Docker Desktop | **≥ 4.92.0**，使用 WSL2 后端（截至 2026-09 的最新版是 4.92.0，发布于 2026-09-21）。4.92.0 修复了"把虚拟磁盘移到其他盘总是失败"的问题。个人使用和小型企业免费 |
| WSL | ≥ 2.1.5 |
| WireGuard for Windows | 官方安装包 |
| 内存 | 建议 ≥ 16 GB |
| 其他 | BIOS 里已开启 CPU 虚拟化；"Server"（LanmanServer）服务处于启用并自动启动状态（Docker Desktop 的要求，默认就是这样） |
| 网络 | 公网 IPv4 + 路由器支持 UDP 端口转发（见 [docs/04-VPN与DDNS.md](04-VPN与DDNS.md)） |

---

## 2. 准备工作

### 2.1 固定局域网 IP

在路由器的"DHCP 静态分配 / IP 与 MAC 绑定"里给这台电脑固定一个地址，例如 `192.168.1.10`。手机访问地址和 VPN 配置都依赖这个 IP。尽量用**有线网络**。

### 2.2 准备一个专用的本地账户（推荐）

Docker Desktop 只有在某个用户**登录之后**才会启动。为了让停电重启、Windows 更新重启后服务能自己恢复，HomeVault 会配置"开机自动登录 + 登录后立即锁屏"。建议：

1. 新建一个**本地账户**，例如 `homevault`，设置一个**独有的强密码**，并加入管理员组（HomeVault 的安装和管理命令需要管理员权限）。请不要用微软账户。
2. 以后**登录这个账户**来安装 Docker Desktop、运行 `.\windows\hv.ps1`，自动登录也用这个账户。
3. 家人日常使用这台电脑时，用各自的账户，通过**切换用户**登录。HomeVault 账户的会话会在后台继续运行。

⚠️ **不要注销** HomeVault 账户。注销会关闭 Docker Desktop，所有服务随之停止。离开时锁屏或切换用户即可。

### 2.3 规划硬盘

先在"此电脑"和"磁盘管理"里看清你有几块**物理硬盘**，每块上有哪些盘符。建议：

| 用途 | 建议 |
|---|---|
| 系统盘 C: | 只放系统和程序 |
| **主数据盘**（例如 D:） | 容量最大、最健康的**内置**硬盘，NTFS 格式 |
| 额外存储（例如 E:） | 已有的照片、资料盘，可以只读挂进 Nextcloud |
| **备份盘**（例如 F:） | **另一块物理硬盘**，内置或 USB 都可以 |
| Docker Desktop 虚拟磁盘 | 从 C: 挪到一块 SSD 或数据盘上（见 §3.3） |

---

## 3. 安装 WSL2 和 Docker Desktop

### 3.1 WSL

用管理员身份打开 PowerShell：

```powershell
wsl --version          # 查看版本；如果提示命令不存在或未安装，执行下一行
wsl --install          # 首次安装，完成后按提示重启
wsl --update           # 已安装的，更新到最新
```

确认 WSL 版本 ≥ 2.1.5。

### 3.2 Docker Desktop

1. 从 Docker 官网下载 Docker Desktop for Windows 安装包（≥ 4.92.0）。
2. **以 HomeVault 账户**运行安装程序，选择 **WSL 2** 后端。
   想在安装时就把 Docker 的数据放到别的盘，可以在安装包所在目录用命令行安装：

   ```powershell
   Start-Process '.\Docker Desktop Installer.exe' -Wait -ArgumentList 'install', '--wsl-default-data-root=D:\DockerDesktop'
   ```

3. 启动 Docker Desktop，打开 **Settings**，检查：

| 位置 | 设置 | 原因 |
|---|---|---|
| General | ✔ **Start Docker Desktop when you sign in to your computer** | 开机自动登录后自动启动 Docker（默认是关闭的！） |
| General | ✔ Use the WSL 2 based engine | HomeVault 使用 WSL2 后端 |
| Resources → Advanced | **Disk image location**：改到 C: 以外的盘，见 §3.3 | 避免 C: 被撑满 |
| Software updates | "Always download updates" 保持关闭（默认） | 由你决定什么时候更新，见 [docs/08-日常运维与升级.md](08-日常运维与升级.md) |

### 3.3 把 Docker Desktop 的虚拟磁盘移出 C:

Docker 的镜像、数据库、Nextcloud 程序文件、证书都存放在一个虚拟磁盘文件里，默认位于 `C:\Users\<用户名>\AppData\Local\Docker\wsl`。

- 在 **Settings → Resources → Advanced → Disk image location** 里选一个新文件夹，例如 `D:\DockerDesktop`，然后应用。
- ⚠️ 4.92.0 之前的版本，移到**另一个盘**会一直失败，请先升级到 ≥ 4.92.0。最好在**创建任何容器之前**就移好。
- 这个虚拟磁盘文件只会变大，不会自动缩小。WSL 虚拟磁盘默认最大 1 TB。HomeVault 的照片和视频不在里面，而是放在 NTFS 数据目录里，所以一般够用。

### 3.4（可选）限制 WSL 占用的内存

WSL2 模式下，内存、CPU 等资源限制在 `%USERPROFILE%\.wslconfig` 里设置，不在 Docker Desktop 界面里。例如：

```ini
[wsl2]
memory=8GB
```

修改后执行 `wsl --shutdown`，再重新启动 Docker Desktop 生效。

### 3.5 国内拉取镜像

国内一般无法直接访问 Docker Hub，wg-easy 所在的 `ghcr.io` 也可能无法访问（Windows 版不用 wg-easy）。两种办法：

1. **推荐：** 安装时加 `--mirror` 参数，把镜像地址整体换成国内镜像站前缀，见 §5.2。
2. 在 Docker Desktop 的 **Settings → Docker Engine** 里加上 `registry-mirrors`（只对 docker.io 有效）：

   ```json
   {
     "registry-mirrors": ["https://docker.m.daocloud.io"]
   }
   ```

公共镜像站通常有白名单和限流规则，拉取失败时换一个试试。详见 [docs/02-Linux部署.md](02-Linux部署.md) §3。

---

## 4. 安装 WireGuard for Windows

1. 从 WireGuard 官方下载并安装：<https://download.wireguard.com/windows-client/wireguard-installer.exe>
2. 装好即可，**不需要**在 WireGuard 界面里手动创建隧道。HomeVault 会：
   - 用 WireGuard 自带的 `wg.exe` 生成密钥；
   - 把服务端配置写到 `C:\ProgramData\HomeVault\wireguard\homevault.conf`，只允许 SYSTEM 和管理员访问；
   - 安装名为 `WireGuardTunnel$homevault` 的隧道服务。它**开机就启动，不需要任何人登录**。

---

## 5. 获取 HomeVault 并运行安装

### 5.1 放到固定位置

把 HomeVault 放到一个**固定目录**，例如 `C:\Tools\homevault`，用 `git clone <仓库地址>` 或下载 ZIP 解压都可以。以后不要移动这个目录：`.env`、`secrets\`、`storage.conf`、`state\` 都会生成在这里，它们也会被一起备份。

⚠️ 不要把 HomeVault 目录放在 Nextcloud 数据目录里面，反过来也不要。

### 5.2 运行安装

以 HomeVault 账户登录，**右键"开始"按钮 → 终端（管理员）/ Windows PowerShell（管理员）**：

```powershell
cd C:\Tools\homevault
# 只对当前窗口放开脚本执行限制
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force
# 解除"从网上下载"标记（下载 ZIP 解压的需要）
Get-ChildItem -Recurse | Unblock-File

.\windows\hv.ps1 install
# 国内网络，使用 DaoCloud 公共镜像前缀：
.\windows\hv.ps1 install --mirror daocloud
# 或者自己输入 docker.io 和 ghcr.io 的镜像前缀：
.\windows\hv.ps1 install --mirror custom
```

`.\windows\install.ps1` 和 `.\windows\hv.ps1 install` 效果相同。

安装程序是交互式的，每个问题都有默认值，直接回车即接受默认值。具体措辞和顺序以屏幕提示为准。大致流程如下：

| 步骤 | 内容 | 建议 |
|---|---|---|
| 预检查 | Docker Desktop 是否在运行、Compose 版本、端口是否被占用、磁盘空间、系统版本 | 有 ✘ 按提示处理后重新运行 |
| 局域网 IP / 网段 | 自动检测，请确认 | 应该就是 §2.1 固定的 IP |
| 访问方式 | IP 模式（`internal`）或域名模式（`acme-dns`） | 有域名推荐域名模式，原因见 [docs/01-架构与安全.md](01-架构与安全.md) §1.3 |
| **硬盘表** | 选择主数据盘、额外存储、备份目标 | 见 §6 |
| VPN | 对外地址 `WG_HOST`（DDNS 域名或公网 IP）、端口 `WG_PORT`（随机） | 记下端口，路由器要用 |
| 开机自启相关 | 是否配置自动登录、登录后锁屏、电源设置 | 见 §7、§8，每项都会先问你 |
| 完成 | 写入 `.env` 和 `secrets\`，启动服务，等待 Nextcloud 就绪，初始化 WireGuard 隧道服务 | — |

安装总结会显示访问地址、管理员 `hvadmin` 的初始密码、根证书指纹（IP 模式）、**restic 备份密码**、路由器端口转发说明和下一步清单。

> ⚠️ 管理员密码和 restic 备份密码**只显示这一次**，请马上保存到密码管理器，restic 密码最好再抄一份在纸上离线保存。

重新运行 `.\windows\hv.ps1 install` 是安全的，不会重新生成密码。

---

## 6. 选择硬盘（多块硬盘时请仔细看）

安装时和运行 `.\windows\hv.ps1 storage list` 时，会显示这样一张表：

```text
盘符 卷标   文件系统 总容量   可用     物理磁盘# SSD/HDD 系统盘 USB BitLocker
C:   系统   NTFS     476 GB   210 GB   0         SSD     是     否  开
D:   数据   NTFS     3.6 TB   3.4 TB   1         HDD     否     否  关
E:   资料   NTFS     1.8 TB   0.4 TB   2         HDD     否     否  关
G:   旧盘   NTFS     931 GB   500 GB   2         HDD     否     否  关
F:   备份   NTFS     4.5 TB   4.5 TB   3         HDD     否     是  关
```

**怎么看这张表：**

- **物理磁盘#** 最重要：编号相同的盘符在**同一块物理硬盘**上。上例中 E: 和 G: 都在 2 号硬盘上，这块硬盘坏了，两个盘符的数据会一起没。
- **SSD/HDD**：固态硬盘或机械硬盘。
- **系统盘**：装 Windows 的那块。
- **USB**：外置 USB 硬盘。
- **BitLocker**：是否已加密，见 [docs/01-架构与安全.md](01-架构与安全.md) §5。

**三种角色：**

| 角色 | 在上例中的选择 | 说明 |
|---|---|---|
| **主数据** | `D:` | 全家的手机照片和视频都在这里，数据目录为 `D:\HomeVault\nextcloud-data`，**在资源管理器里能直接看到**，重置 Docker Desktop 也不会丢 |
| **额外存储** | `E:\照片归档`（读写）、`G:\影视`（只读） | 已有文件夹挂进 Nextcloud，可以设为只读，也可以只给某些人看 |
| **备份目标** | `F:` | 和主数据**不在同一块物理硬盘上**（物理磁盘# 3 ≠ 1） |

安装程序会在这些情况给出警告：

- ⚠️ 主数据选了**系统盘**：重装系统或系统盘故障会同时威胁数据；
- ⚠️ 主数据选了 **USB 外置盘**：拔掉或盘符变化后 Nextcloud 无法启动；
- ⚠️ 选了 **FAT32**（单个文件不能超过 4 GB，手机长视频会失败）或 **exFAT**（没有权限控制，断电容易损坏）。建议改用 NTFS；
- ⚠️⚠️ **备份目标和主数据（或某个读写的额外存储）在同一块物理硬盘上**：这块硬盘坏了，数据和备份会一起丢。请换一块硬盘，或者用 S3 异地备份。

**备份盘用 USB 移动硬盘可以吗？** 可以，但要保证备份时间（默认 03:30）它是插着的，而且**盘符不能变**。可以在"磁盘管理"里给它固定一个不常用的盘符（例如 `R:`）。

### 6.1 以后管理额外存储

```powershell
.\windows\hv.ps1 storage list
.\windows\hv.ps1 storage add          # 交互式添加
.\windows\hv.ps1 storage remove 影视资料
.\windows\hv.ps1 storage apply
```

配置保存在 `storage.conf`，格式和 Linux 版相同：

```text
# 名称|主机路径|rw或ro|是否备份(yes/no)|可见用户(空=所有用户; 逗号分隔; @开头为群组)
照片归档|E:\照片归档|rw|yes|
影视资料|G:\影视|ro|no|@family
```

---

## 7. 开机自启链：停电来电后能自己恢复

Windows 上，从通电到服务恢复，要经过下面这一串步骤。每一环都要配置好：

```mermaid
flowchart TD
  A["通电<br/>BIOS：来电自动开机"] --> B["Windows 启动"]
  B --> C["WireGuard 隧道服务 WireGuardTunnel$homevault<br/>开机即运行，无需登录"]
  B --> D["计划任务 HomeVault-WeakHost（SYSTEM）<br/>开机时 + 每 5 分钟：设置弱主机模式"]
  B --> E["Autologon 自动登录 HomeVault 账户"]
  E --> F["计划任务 HomeVault-Lock<br/>登录后立即锁屏"]
  E --> G["Docker Desktop 随登录启动"]
  G --> H["容器自动恢复<br/>restart: unless-stopped"]
  H --> I["每晚：计划任务 HomeVault-Backup"]
```

```text
通电 ─▶ (BIOS 来电开机) ─▶ Windows 启动 ─┬─▶ WireGuard 隧道服务（无需登录）
                                          ├─▶ HomeVault-WeakHost 任务（SYSTEM）
                                          └─▶ Autologon 自动登录 ─┬─▶ HomeVault-Lock 立即锁屏
                                                                  └─▶ Docker Desktop ─▶ 容器恢复
```

### 7.1 自动登录（Sysinternals Autologon）

安装程序会询问是否配置。如果系统有 winget，它会尝试用 `winget install Microsoft.Sysinternals.Autologon` 安装 Autologon；否则请手动从微软官网下载 Sysinternals Autologon。手动配置方法：

1. 以 HomeVault 账户运行 Autologon；
2. 填写用户名（HomeVault 账户）、域（本地账户填这台电脑的名字）和密码，点 **Enable**。

需要知道的几点：

- 密码以加密形式保存在注册表里（LSA 机密），但**任何有管理员权限的人都能取出来**。所以这个账户的密码不要和别处共用。
- 开机时**按住 Shift 键**，可以跳过这一次自动登录。
- 想取消自动登录，再次运行 Autologon，点 **Disable**。

### 7.2 登录后立即锁屏（计划任务 `HomeVault-Lock`）

自动登录后，桌面不能一直开着给路过的人用。安装程序会创建计划任务 `HomeVault-Lock`：用户一登录就锁定工作站。锁屏**不会**影响 Docker Desktop 和容器的运行。

### 7.3 Docker Desktop 随登录启动

确认 Docker Desktop 设置里已勾选 **Start Docker Desktop when you sign in to your computer**（§3.2）。`doctor` 会提醒你检查这一项。

### 7.4 验证

配好之后，**重启一次**电脑，什么都不要动，等 3–5 分钟：

- 屏幕应显示锁屏界面；
- 手机（关掉 Wi-Fi，用流量连 VPN）能打开 Nextcloud；
- 解锁后运行 `.\windows\hv.ps1 doctor`，全部 ✔。

---

## 8. 电源设置和 BIOS

### 8.1 不睡眠、不休眠

安装程序会先征求你的同意，再设置"接通电源时从不睡眠"。等价的手动命令（管理员 PowerShell）：

```powershell
powercfg /change standby-timeout-ac 0     # 从不睡眠
powercfg /change hibernate-timeout-ac 0   # 从不休眠
powercfg /change disk-timeout-ac 0        # 从不关闭硬盘
powercfg /hibernate off
```

显示器可以正常关闭，不影响服务。

### 8.2 BIOS：来电自动开机

停电后来电，电脑要能自己开机。进入 BIOS/UEFI 设置，找到类似 **Restore on AC Power Loss**、**AC Back**、**After Power Failure** 的选项（名字因主板厂商而异），设为 **Power On**。

⚠️ 如果 BitLocker 设置了**开机 PIN**，来电开机后会一直停在输入 PIN 的界面，后面的自启链都不会发生。无人值守的服务器请使用 TPM 自动解锁。

### 8.3 Windows 更新重启

Windows 更新后需要重启，重启后 §7 的自启链会自动恢复服务，所以**允许它在夜间自动重启**即可：

- 在 **设置 → Windows 更新 → 高级选项 → 使用时段** 里，把白天常用的时间段设为使用时段，让重启发生在夜里；
- 夜间重启可能打断正在进行的备份，下一次备份会重新进行；
- 第二天早上随手运行一次 `.\windows\hv.ps1 doctor` 看看。

---

## 9. Windows 防火墙

```powershell
.\windows\hv.ps1 firewall --apply   # 创建/更新规则
.\windows\hv.ps1 firewall --show    # 查看
```

HomeVault 会添加这些规则（适用于所有网络类型，`-Profile Any`）：

| 规则 | 允许 |
|---|---|
| HTTPS / HTTP | TCP `HV_HTTPS_PORT` / `HV_HTTP_PORT`，**只允许**来源是局域网网段（`HV_LAN_CIDR`）和 VPN 网段（`HV_VPN_CIDR`） |
| WireGuard | UDP `WG_PORT` |

为什么规则要适用于所有网络类型：WireGuard 的隧道网卡通常被 Windows 识别为"未识别的网络"，也就是**公用网络**。规则只写"专用网络"的话，VPN 客户端会被挡住。

规则里只列了 IPv4 网段，所以**来自 IPv6 的连接不会被放行**（原因见 [docs/01-架构与安全.md](01-架构与安全.md) §3.2）。

### 9.1 检查 Docker Desktop 的宽泛放行规则

Docker Desktop 安装时，可能会给它的后台程序 `com.docker.backend.exe` 添加"允许任何来源"的入站规则。这类规则会绕过上面按地址限制的规则。`firewall` 命令和 `doctor` 都会检查并警告。你也可以手动查看：

```powershell
Get-NetFirewallApplicationFilter -Program *com.docker.backend.exe | Get-NetFirewallRule |
  Where-Object { $_.Direction -eq 'Inbound' -and $_.Action -eq 'Allow' -and $_.Enabled -eq 'True' } |
  Select-Object DisplayName, Profile
```

如果列出了规则，建议**禁用**它们（例如 `Disable-NetFirewallRule -DisplayName "<上面显示的名称>"`）。HomeVault 自己的端口规则仍然允许局域网和 VPN 访问，不影响正常使用。禁用后运行 `.\windows\hv.ps1 doctor` 确认。

---

## 10. VPN：弱主机模式是什么

手机通过 VPN 访问的仍然是 `https://<局域网 IP>`。但这些数据包是从 WireGuard 的隧道网卡进来的，而局域网 IP 属于另一块网卡（有线网卡）。Windows 默认采用"强主机模式"，会**丢弃**这种数据包。

HomeVault 的做法是：

- 对隧道网卡（名称 `homevault`）开启**弱主机接收/发送**（`WeakHostReceive` / `WeakHostSend`）；
- 隧道服务每次重启，这块网卡都会被重新创建，设置也随之丢失。所以 HomeVault 创建了以 SYSTEM 身份运行的计划任务 `HomeVault-WeakHost`：开机时运行，之后每 5 分钟运行一次，每次修改 VPN 客户端后也会立即运行；
- IP 模式下，站点地址里还额外包含隧道地址（例如 `https://10.99.77.1`），可以作为排错时的备用地址。

检查是否生效：

```powershell
Get-NetIPInterface -InterfaceAlias homevault |
  Select-Object InterfaceAlias, AddressFamily, WeakHostReceive, WeakHostSend
```

两列都应显示 `Enabled`。`doctor` 也会检查这一项。

**管理 VPN 客户端：**

```powershell
.\windows\hv.ps1 vpn status              # 隧道服务状态
.\windows\hv.ps1 vpn add                 # 添加一台设备：生成配置，在浏览器里显示二维码
.\windows\hv.ps1 vpn list                # 列出所有设备
.\windows\hv.ps1 vpn qr <名称>           # 重新显示二维码
.\windows\hv.ps1 vpn remove <名称>       # 删除一台设备（手机丢失时用）
```

- 客户端私钥**不会**保存在服务器上。生成的配置文件（`clients\<名称>.conf`）和二维码页面用完后，程序会提示你删除。
- Windows 版不做 NAT 和转发，VPN 客户端本来就只能访问这台电脑。

更多内容（DDNS、NAT 回流、网段冲突）见 [docs/04-VPN与DDNS.md](04-VPN与DDNS.md)。

---

## 11. NTFS 数据目录的注意事项

Nextcloud 的主数据目录（例如 `D:\HomeVault\nextcloud-data`）放在 NTFS 上。这样文件能直接在资源管理器里看到，重置 Docker Desktop 也不会丢，但有几点代价：

1. **不区分大小写。** Linux 和 Nextcloud 认为 `IMG_001.jpg` 和 `img_001.jpg` 是两个不同的文件，NTFS 却认为它们是同一个。同一个文件夹里上传这样两个只有大小写不同的文件，会产生冲突或上传失败。手机相机生成的文件名一般不会这样，但从其他电脑整理上传时要注意。
2. ⚠️ **不要在资源管理器里直接修改 `nextcloud-data` 里的文件。** Nextcloud 用数据库记录文件，在 Windows 上又收不到文件变化通知。直接在这里添加、删除、重命名的文件，Nextcloud 不会知道，可能出现"看得见打不开"等问题。
   - 需要在 Windows 上直接整理的文件夹，请用 `storage add` 挂成**额外存储**。额外存储在访问时会检查变化；
   - 确实动过数据目录的，运行 `.\windows\hv.ps1 occ files:scan --all` 让 Nextcloud 重新扫描。
3. **速度较慢。** 容器通过 WSL2 访问 Windows 磁盘比访问 Linux 文件系统慢，对家庭备份来说一般够用。
4. **权限检查已自动关闭。** NTFS 上无法设置 Linux 权限，HomeVault 在安装时自动为 Windows 设置 `check_data_directory_permissions=false`（Nextcloud 官方文档为"Docker on Windows"提供的选项）。所以请保护好 Windows 这一侧的访问权限：不要把数据目录共享给局域网，也不要让不信任的账户访问它。
5. **不要把数据目录放在 USB 硬盘或网络驱动器上。**

数据库、Nextcloud 程序文件、证书等仍然放在 Docker 的**命名卷**里（Docker Desktop 的虚拟磁盘内）。数据库绝不能放在 NTFS 上。

---

## 12. 替代方案：Hyper-V 虚拟机 + Linux 套件（仅专业版）

Windows 专业版、企业版、教育版可以用 Hyper-V 虚拟机运行一台 Ubuntu Server，里面**原样**使用 Linux 版 HomeVault。

**优点：** 虚拟机可以随 Windows 开机自动启动，不需要自动登录；WireGuard 在内核里运行；没有 NTFS 的限制。
**缺点：** 硬盘需要分给虚拟机使用；要多学一点 Hyper-V 知识；家庭版不能用。

大致步骤：

1. 在"启用或关闭 Windows 功能"里勾选 **Hyper-V**，重启。
2. 打开 **Hyper-V 管理器 → 虚拟交换机管理器**，新建一个**外部**虚拟交换机，绑定到有线网卡。这样虚拟机能在局域网里拿到自己的 IP。
3. 新建第 2 代虚拟机，内存 ≥ 4 GB，挂载 Ubuntu Server 安装镜像，网络选刚才的外部交换机。数据盘可以二选一：
   - 在数据盘上创建一个大的虚拟硬盘文件；
   - 把一整块物理硬盘直通给虚拟机（先在"磁盘管理"里把它设为脱机）。
4. 设置随 Windows 开机自动启动：

   ```powershell
   Set-VM -Name HomeVault -AutomaticStartAction Start
   ```

5. 在路由器上给**虚拟机的 IP** 固定地址，并把 UDP `WG_PORT` 转发到**虚拟机的 IP**。
6. 在虚拟机里按 [docs/02-Linux部署.md](02-Linux部署.md) 部署。

⚠️ 同一台电脑上只运行一套 HomeVault：选了虚拟机方案，就不要再在 Windows 上运行 `hv.ps1 install`。

---

## 13. 首次登录、家人账户和备份

Windows 版的这些步骤和 Linux 版完全相同，只是命令写法不同：

| 事项 | 命令 | 详细说明 |
|---|---|---|
| 导出根证书（IP 模式） | `.\windows\hv.ps1 ca --export C:\Users\Public\homevault-ca.crt` | 命令会显示指纹和各系统的安装方法。本机安装：`certutil -addstore -f "ROOT" C:\Users\Public\homevault-ca.crt` |
| 首次登录 + 二步验证 | 浏览器打开 `https://<局域网IP>` | [docs/02-Linux部署.md](02-Linux部署.md) §10 |
| 创建家人账户 | `.\windows\hv.ps1 user add mama --display-name "妈妈" --quota 500GB` | [docs/02-Linux部署.md](02-Linux部署.md) §11 |
| 定时备份 | `.\windows\hv.ps1 schedule-backup`（可加 `--time 03:30`） | 创建计划任务 `HomeVault-Backup`，以已登录的 HomeVault 账户身份运行 `hv.ps1 backup`。见 [docs/07-备份与恢复.md](07-备份与恢复.md) |
| 手机设置 | — | [docs/05-安卓手机备份.md](05-安卓手机备份.md) |
| 体检 | `.\windows\hv.ps1 doctor` | 额外检查：隧道服务在运行、弱主机模式已生效、自动登录和 Docker 自启动的提示 |

路由器端口转发：**UDP `WG_PORT` → 这台电脑的局域网 IP**，只转发这一个端口，不要开 DMZ。详见 [docs/04-VPN与DDNS.md](04-VPN与DDNS.md)。

---

## 14. Windows 常见问题速查

| 现象 | 可能原因 | 处理 |
|---|---|---|
| 重启后手机连不上 Nextcloud，但 VPN 显示已连接 | 没有自动登录，Docker Desktop 没启动 | 检查 §7；看屏幕是否停在登录界面 |
| VPN 已连接，但打不开 `https://<局域网IP>` | 弱主机模式没生效 | 见 §10 的检查命令；运行 `.\windows\hv.ps1 doctor` |
| 局域网能访问，VPN 不行，也不是上一条的原因 | 防火墙规则没覆盖公用网络 | `.\windows\hv.ps1 firewall --apply` |
| 移动 Docker 虚拟磁盘失败 | Docker Desktop 版本低于 4.92.0 | 升级后重试 |
| C: 空间越来越少 | Docker 虚拟磁盘还在 C: 上 | §3.3 |
| 大小写不同的同名文件上传失败 | NTFS 不区分大小写 | §11 |

更多问题见 [docs/09-常见问题.md](09-常见问题.md)。

---

## 来源 / 参考

版本信息截至 2026-09：

- Docker Desktop for Windows 安装要求（Windows 版本、WSL ≥ 2.1.5、安装参数 `--wsl-default-data-root`）：<https://docs.docker.com/desktop/setup/install/windows-install/>
- Docker Desktop 设置（"Start Docker Desktop when you sign in to your computer"、Disk image location）：<https://docs.docker.com/desktop/settings-and-maintenance/settings/>
- Docker Desktop 发布说明（4.92.0 修复跨盘移动虚拟磁盘）：<https://docs.docker.com/desktop/release-notes/>
- Docker Desktop WSL2 后端与最佳实践：<https://docs.docker.com/desktop/features/wsl/>
- Docker Desktop 网络（端口由 `com.docker.backend.exe` 转发）：<https://docs.docker.com/desktop/features/networking/>
- "开机不登录无法启动 Docker Desktop"的功能请求：<https://github.com/docker/roadmap/issues/515>
- Docker Desktop 许可：<https://docs.docker.com/subscription/desktop-license/>
- WSL 配置（`.wslconfig`）与磁盘空间：<https://learn.microsoft.com/windows/wsl/wsl-config> · <https://learn.microsoft.com/windows/wsl/disk-space>
- WSL 文件权限（Windows 磁盘上的权限行为）：<https://learn.microsoft.com/windows/wsl/file-permissions>
- WireGuard for Windows（隧道服务、`/installtunnelservice`、网络说明）：<https://github.com/WireGuard/wireguard-windows/blob/master/docs/enterprise.md> · <https://github.com/WireGuard/wireguard-windows/blob/master/docs/netquirk.md>
- `Set-NetIPInterface`（WeakHostReceive / WeakHostSend）：<https://learn.microsoft.com/powershell/module/nettcpip/set-netipinterface>
- `New-NetFirewallRule`：<https://learn.microsoft.com/powershell/module/netsecurity/new-netfirewallrule>
- Sysinternals Autologon：<https://learn.microsoft.com/sysinternals/downloads/autologon>
- `Set-VM`（AutomaticStartAction）：<https://learn.microsoft.com/powershell/module/hyper-v/set-vm>
- Nextcloud `check_data_directory_permissions`：<https://docs.nextcloud.com/server/latest/admin_manual/configuration_server/config_sample_php_parameters.html>
- Windows 10 支持结束与 ESU：<https://www.microsoft.com/windows/end-of-support>
- DaoCloud 公共镜像加速：<https://github.com/DaoCloud/public-image-mirror>
