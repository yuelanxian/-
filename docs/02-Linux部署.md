# 02 · Linux 部署（Debian / Ubuntu）

本文带你在一台 Debian 或 Ubuntu 电脑上从零部署 HomeVault。整个过程大约 30–60 分钟，不包括第一次备份（数据多的话要几个小时）。

相关文档：[docs/01-架构与安全.md](01-架构与安全.md) · [docs/04-VPN与DDNS.md](04-VPN与DDNS.md) · [docs/05-安卓手机备份.md](05-安卓手机备份.md) · [docs/07-备份与恢复.md](07-备份与恢复.md) · [docs/08-日常运维与升级.md](08-日常运维与升级.md)

> 约定：本文的命令都在 HomeVault 目录（例如 `/opt/homevault`）里执行。`./hv` 需要 root 权限，所以写成 `sudo ./hv ...`；如果你已经是 root，去掉 `sudo` 即可。`./hv help` 可以列出全部命令。

---

## 0. 部署路线图

| 步骤 | 内容 | 章节 |
|---|---|---|
| 1 | 检查硬件、系统和网络 | [§1](#1-准备工作) |
| 2 | 安装 Docker CE 和 Compose 插件 | [§2](#2-安装-docker-ce国内用阿里云镜像源) |
| 3 | 解决国内拉取镜像的问题 | [§3](#3-国内拉取镜像docker-hub-加速) |
| 4 | 规划、格式化并挂载硬盘（可选磁盘加密） | [§4](#4-规划和挂载硬盘) |
| 5 | 获取 HomeVault，运行 `./hv install` | [§5](#5-获取-homevault)、[§6](#6-运行-hv-install逐项说明) |
| 6 | 选择硬盘的角色 | [§7](#7-硬盘角色主数据--额外存储--备份目标) |
| 7 | 防火墙、路由器端口转发 | [§8](#8-主机防火墙)、[§9](#9-路由器端口转发) |
| 8 | 首次登录、二步验证、创建家庭成员账户 | [§10](#10-首次登录和二步验证)、[§11](#11-创建家庭成员账户) |
| 9 | 设置定时备份，体检 | [§12](#12-设置定时备份)、[§13](#13-体检hv-doctor) |

---

## 1. 准备工作

### 1.1 硬件

- 一台 64 位（x86-64）电脑，内存建议 ≥ 4 GB，系统盘最好是 SSD。
- 至少一块大容量**数据盘**，用来放照片和视频。
- 强烈建议再准备一块**不同的物理硬盘**当**备份盘**，内置或 USB 都可以。
- 用网线连接路由器，比 Wi-Fi 稳定得多。

### 1.2 系统

- **Debian 或 Ubuntu**，选择 Docker 官方仍在支持的版本（例如较新的 Debian 稳定版或 Ubuntu LTS）。建议用不带桌面的服务器版。
- 安装系统时开启 OpenSSH 服务器，方便以后在别的电脑上远程管理。
- 另外装几个常用工具：

```bash
sudo apt-get update
sudo apt-get install -y git curl ca-certificates acl
# 可选：磁盘加密、硬盘健康检查、ufw 防火墙
sudo apt-get install -y cryptsetup smartmontools ufw
```

### 1.3 网络

1. **固定局域网 IP。** 在路由器的"DHCP 静态分配 / IP 与 MAC 绑定"里，给这台电脑固定一个地址，例如 `192.168.1.10`。HomeVault 的访问地址和 VPN 配置都依赖这个 IP，**以后最好不要再改**。
2. **确认有公网 IPv4。** 对比路由器 WAN 口显示的 IP 和 `curl https://4.ipw.cn` 的结果。两者相同，说明有公网 IP；如果 WAN 口地址是 `100.64.x.x`–`100.127.x.x` 或其他私有地址，说明你在运营商级 NAT 后面。详见 [docs/04-VPN与DDNS.md](04-VPN与DDNS.md)。
3. 可选但推荐：准备一个域名，用来做 DDNS 和"域名模式"证书。

---

## 2. 安装 Docker CE（国内用阿里云镜像源）

HomeVault 要求 **Docker Engine ≥ 28** 和 **Docker Compose 插件 ≥ 2.24**。

⚠️ **不要**安装发行版仓库里的 `docker.io` / `docker-compose` 包，它们的版本往往太旧。请安装 Docker 官方的 Docker CE。国内访问 `download.docker.com` 可能很慢，可以用阿里云镜像源 `mirrors.aliyun.com/docker-ce`，两者内容相同：

```bash
# 1. 删除可能冲突的旧包（没装过也不要紧）
for p in docker.io docker-compose docker-doc podman-docker containerd runc; do sudo apt-get remove -y $p; done

# 2. 添加 Docker CE 软件源（阿里云镜像）
sudo install -m 0755 -d /etc/apt/keyrings
. /etc/os-release        # 得到 ID（debian 或 ubuntu）和 VERSION_CODENAME
sudo curl -fsSL "https://mirrors.aliyun.com/docker-ce/linux/${ID}/gpg" -o /etc/apt/keyrings/docker.asc
sudo chmod a+r /etc/apt/keyrings/docker.asc
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://mirrors.aliyun.com/docker-ce/linux/${ID} ${VERSION_CODENAME} stable" \
  | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

# 3. 安装
sudo apt-get update
sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

# 4. 开机自启并检查版本
sudo systemctl enable --now docker
docker version --format 'Engine: {{.Server.Version}}'   # 应 ≥ 28
docker compose version                                   # 应 ≥ 2.24
```

> 在海外或网络通畅时，把上面的 `https://mirrors.aliyun.com/docker-ce` 换成 `https://download.docker.com` 即可。

为什么要求 Engine ≥ 28：旧版本存在一个问题，同一局域网里的其他主机能够访问到只发布在 `127.0.0.1` 上的端口，从 28.0 起已修复。HomeVault 的 Scrutiny 等服务依赖"只绑定本机"这一点。

---

## 3. 国内拉取镜像（Docker Hub 加速）

从 2024 年 6 月起，中国大陆基本无法直接访问 Docker Hub。wg-easy 和 Scrutiny 的镜像放在 `ghcr.io` 上，同样可能无法访问。HomeVault 在 `.env` 里保存**完整的镜像地址**（例如 `docker.io/library/nextcloud:34-apache`），所以可以整体替换成国内镜像站的前缀。

### 方法一（推荐）：安装时使用 `--mirror`

```bash
sudo ./hv install --mirror custom
```

- `--mirror custom` 会请你分别输入 `docker.io/` 和 `ghcr.io/` 要替换成的前缀。例如 DaoCloud 公共镜像的前缀分别是 `docker.m.daocloud.io/` 和 `ghcr.m.daocloud.io/`。
- `--mirror` 也接受内置的预设名，例如 `--mirror daocloud` 直接使用上面这组 DaoCloud 前缀；可用的预设以 `./hv help` 为准。
- 选择了镜像后，域名模式下构建 Caddy 所用的 Go 模块代理 `HV_GOPROXY` 会默认改为 `https://goproxy.cn,direct`。

### 方法二：Docker 守护进程的 `registry-mirrors`（只对 docker.io 有效）

编辑 `/etc/docker/daemon.json`（没有就新建）：

```json
{
  "registry-mirrors": ["https://docker.m.daocloud.io"]
}
```

```bash
sudo systemctl restart docker
```

⚠️ 注意：

- `registry-mirrors` **只能**加速 `docker.io` 上的镜像。DaoCloud 明确提醒不要把 docker.io 以外的镜像站填进这里，所以 wg-easy（`ghcr.io`）仍需要方法一。
- 公共镜像站通常有白名单和限流规则，可用性也会变化。拉取失败时，请换一个镜像站，或稍后重试。
- 只使用你信任的镜像站（见 [docs/01-架构与安全.md](01-架构与安全.md) 第 6 节"镜像供应链"）。

---

## 4. 规划和挂载硬盘

### 4.1 推荐的目录布局

| 用途 | 建议位置 | 说明 |
|---|---|---|
| HomeVault 程序（本仓库） | `/opt/homevault` | 放在系统盘上 |
| 程序数据 `HV_DATA_DIR`（数据库、Nextcloud 程序文件、证书等） | 例如 `/srv/homevault`（系统盘 SSD） | 数据库放在 SSD 上更快 |
| **主数据目录** `HV_NC_DATA_PATH`（照片、视频） | 例如 `/mnt/data1/nextcloud-data`（大容量数据盘） | 全家的文件都在这里 |
| 额外存储（已有资料盘） | 例如 `/mnt/data2/影视资料` | 可以只读挂进 Nextcloud |
| 备份仓库 `HV_BACKUP_LOCAL_PATH` | 例如 `/mnt/backup/homevault-restic` | **必须在另一块物理硬盘上** |

安装程序会根据你的选择设置这些路径，之后也可以在 `.env` 里修改（改完需要重新 `./hv up`）。

### 4.2 选择文件系统

| 文件系统 | 优点 | 缺点 | 建议用于 |
|---|---|---|---|
| **ext4** | 最成熟、最简单、出了问题最容易找到帮助 | 只校验元数据，**不校验文件内容**，无法发现静默损坏（比特腐烂） | 不想折腾时的主数据盘；备份盘 |
| **btrfs** | 文件内容也有校验和，定期"擦洗"（scrub）能发现损坏；支持快照 | 概念稍多；有些操作需要额外学习 | 愿意多学一点时的主数据盘 |

- 用 btrfs 时，建议格式化成 `-d single -m dup`（数据一份，元数据两份），每月执行一次 `btrfs scrub`。scrub 发现损坏的文件时，从 restic 备份里恢复这个文件（见 [docs/07-备份与恢复.md](07-备份与恢复.md)）。
- ⚠️ 不要对 btrfs 上的目录执行 `chattr +C`（关闭写时复制），它会同时关掉这些文件的数据校验。
- ⚠️ **不要**把主数据盘格式化成 FAT32 或 exFAT：它们不支持 Linux 权限，FAT32 还有单个文件最大 4 GB 的限制。安装程序遇到这种情况会给出警告。
- 备份盘用 ext4 就行，restic 自己会校验数据完整性。

### 4.3 格式化新硬盘

⚠️ **格式化会清空整块硬盘！** 请反复确认设备名，最好用 `/dev/disk/by-id/...` 这种不会变的名字。

```bash
# 查看所有硬盘：型号、大小、是否机械盘（ROTA=1）、接口（TRAN=usb 表示 USB）
lsblk -o NAME,SIZE,MODEL,SERIAL,ROTA,TRAN,FSTYPE,MOUNTPOINT
ls -l /dev/disk/by-id/ | grep -v part

# 假设新数据盘是 /dev/sdb（请替换成你的！）
sudo parted /dev/sdb --script mklabel gpt mkpart hvdata 0% 100%

# 二选一：
sudo mkfs.ext4 -L hvdata /dev/sdb1
# 或
sudo mkfs.btrfs -L hvdata -d single -m dup /dev/sdb1
```

### 4.4 开机自动挂载：按 UUID，并加 `nofail`

```bash
sudo mkdir -p /mnt/data1
sudo blkid /dev/sdb1          # 记下 UUID="...."
sudo nano /etc/fstab
```

在 `/etc/fstab` 末尾加一行（二选一）：

```fstab
# ext4
UUID=你的UUID  /mnt/data1  ext4   defaults,noatime,nofail  0  2
# btrfs
UUID=你的UUID  /mnt/data1  btrfs  defaults,noatime,nofail  0  0
```

```bash
sudo systemctl daemon-reload
sudo mount -a && findmnt /mnt/data1     # 能看到挂载信息就成功了
```

- **用 UUID**：硬盘的 `sdb`、`sdc` 这类名字，重启后可能会互换，UUID 不会变。
- **加 `nofail`**：某块硬盘坏了或没插时，系统仍然能正常开机，你还能远程登录处理。

### 4.5 让 Docker 等硬盘挂载好再启动（重要）

加了 `nofail` 后，如果硬盘没挂上，Docker 可能会对着一个**空目录**启动 Nextcloud，把文件写到系统盘上。为了避免这种情况，给 Docker 加一个启动依赖：

```bash
sudo mkdir -p /etc/systemd/system/docker.service.d
sudo tee /etc/systemd/system/docker.service.d/homevault.conf > /dev/null <<'EOF'
[Unit]
RequiresMountsFor=/mnt/data1 /mnt/data2
EOF
sudo systemctl daemon-reload
```

把 `/mnt/data1 /mnt/data2` 换成主数据盘和额外存储实际用到的挂载点，用空格分隔。

- 一直装在机器里的内置备份盘，也可以列进去。
- ⚠️ **经常拔插的 USB 备份盘不要列进去**，否则它没插的时候 Docker 就起不来。USB 盘没插时，当晚的备份会因为找不到备份仓库而失败，`doctor` 随后会提示上次备份时间过久，但不会影响 Nextcloud 本身。

### 4.6（可选）LUKS2 磁盘加密

原理和取舍见 [docs/01-架构与安全.md](01-架构与安全.md) 第 5 节。在格式化成 ext4/btrfs **之前**完成：

```bash
DISK=/dev/disk/by-id/ata-你的硬盘ID          # 整块盘或分区都可以
sudo cryptsetup luksFormat --type luks2 "$DISK"   # 设置一个口令（第 0 号密钥槽）
# 立即备份 LUKS 头，保存到这块硬盘以外的安全位置（U 盘、另一台电脑）
sudo cryptsetup luksHeaderBackup "$DISK" --header-backup-file ./hv-luks-header.img
sudo cryptsetup open "$DISK" hvdata
sudo mkfs.btrfs -L homevault -d single -m dup /dev/mapper/hvdata   # 或 mkfs.ext4
sudo blkid "$DISK"      # 记下 LUKS 分区自身的 UUID（TYPE="crypto_LUKS"）
```

开机自动解锁，二选一：

**方式 A：密钥文件放在系统盘上**（只能防"单独偷走数据盘"，整台电脑被偷则无效）

```bash
sudo install -d -m 0700 /etc/cryptsetup-keys.d
sudo dd if=/dev/urandom of=/etc/cryptsetup-keys.d/hvdata.key bs=4096 count=1
sudo chmod 0400 /etc/cryptsetup-keys.d/hvdata.key
sudo cryptsetup luksAddKey "$DISK" /etc/cryptsetup-keys.d/hvdata.key
echo 'hvdata UUID=LUKS分区的UUID none luks,nofail' | sudo tee -a /etc/crypttab
```

`/etc/crypttab` 的密钥字段写 `none` 时，systemd 会自动去读 `/etc/cryptsetup-keys.d/hvdata.key`。

**方式 B：绑定 TPM2 芯片**（主板要有并开启 TPM2）

```bash
sudo systemd-cryptenroll --tpm2-device=auto --tpm2-pcrs=7 "$DISK"
sudo systemd-cryptenroll --recovery-key "$DISK"       # 生成恢复密钥，务必离线保存！
echo 'hvdata UUID=LUKS分区的UUID none tpm2-device=auto,nofail' | sudo tee -a /etc/crypttab
```

PCR 7 对应安全启动（Secure Boot）状态。升级固件或修改安全启动设置后，可能需要用恢复密钥解锁，再重新绑定：`systemd-cryptenroll --wipe-slot=tpm2 --tpm2-device=auto "$DISK"`。

两种方式的 `/etc/fstab` 都挂载解密后的设备：

```fstab
/dev/mapper/hvdata  /mnt/data1  btrfs  defaults,noatime,nofail  0  0
```

⚠️ crypttab 里写了 `nofail`，fstab 里也必须写 `nofail`，否则硬盘解锁失败时系统会开不了机。别忘了 §4.5 的 Docker 启动依赖。

---

## 5. 获取 HomeVault

```bash
sudo git clone <仓库地址> /opt/homevault
cd /opt/homevault
./hv help
```

放好后**不要随意移动**这个目录。`.env`、`secrets/`、`storage.conf`、`state/` 都会生成在这里，它们也会被一起备份。

---

## 6. 运行 `./hv install`（逐项说明）

```bash
sudo ./hv install
# 国内网络：
sudo ./hv install --mirror custom
```

安装程序是**交互式**的，会按顺序询问下面这些问题。每个问题都有默认值，直接按回车就是接受默认值。具体措辞和顺序以屏幕上的提示为准。

### 6.1 环境预检查（自动）

安装程序会检查：Docker 和 Compose 版本（Engine ≥ 28、Compose ≥ 2.24）；需要的端口（默认 80、443、8443）有没有被占用；磁盘空间是否足够；操作系统是否受支持。有 ✘ 时按提示处理后重新运行即可。

### 6.2 问题清单

| 询问内容 | 对应设置 | 建议 |
|---|---|---|
| 局域网 IP 和网段（自动检测，请确认） | `HV_LAN_IP`、`HV_LAN_CIDR` | 确认是 §1.3 里固定的那个 IP，例如 `192.168.1.10` 和 `192.168.1.0/24` |
| 访问方式：IP 模式还是域名模式 | `HV_TLS_MODE`（`internal` / `acme-dns`）、`HV_HOST` | 有域名选域名模式（手机不用装证书）；没有就选 IP 模式，`HV_HOST` 等于局域网 IP |
| 域名模式：DNS 服务商、API 密钥、邮箱 | `HV_DNS_PROVIDER`、`HV_ACME_EMAIL`，密钥写入 `secrets/caddy-dns.env` | 服务商可选 `alidns` / `tencentcloud` / `cloudflare`。⚠️ 用只有 DNS 权限的子账号密钥。域名的 A 记录要指向**局域网 IP** |
| 端口 | `HV_HTTPS_PORT`（443）、`HV_HTTP_PORT`（80）、`HV_ADMIN_PORT`（8443） | 没有冲突就保持默认。也可以用参数 `--https-port`、`--http-port`、`--admin-port` 指定 |
| 硬盘表和**主数据目录** | `HV_NC_DATA_PATH` | 见 [§7](#7-硬盘角色主数据--额外存储--备份目标) |
| 额外存储（可以添加 0 个或多个） | 写入 `storage.conf` | 见 §7 |
| **备份目标**：本地目录或 S3 | `HV_BACKUP_TARGET`、`HV_BACKUP_LOCAL_PATH` 或 `HV_BACKUP_S3_REPO`、`HV_BACKUP_S3_OPTIONS` | 首选另一块物理硬盘；S3 的访问密钥写入 `secrets/backup.env` |
| VPN 对外地址 | `WG_HOST` | 填 DDNS 域名，例如 `vpn.example.com`；也可以填公网 IP，但 IP 一变就连不上 |
| VPN 端口 | `WG_PORT` | 默认在 20000–60000 之间随机选一个，**记下来**，下一步路由器要用 |
| VPN 访问范围 | `HV_VPN_LAN_ACCESS`（`host` / `full`） | 保持 `host`（只能访问这台主机），原因见 [docs/01-架构与安全.md](01-架构与安全.md) §3.5 |
| 是否启用 DDNS | `HV_DDNS_ENABLED` 等 | 也可以之后用 `./hv ddns setup` 设置，见 [docs/04-VPN与DDNS.md](04-VPN与DDNS.md) |

不需要 VPN（例如只在家里局域网用）时，可以加 `--no-vpn`。

### 6.3 安装程序接下来会自动完成

1. 写入 `.env`，用随机数生成 `secrets/` 里的各个密码；
2. 创建数据目录（Nextcloud 目录的属主设为 `33:33`，即容器里的 www-data；数据目录权限为 0750）；
3. 根据 `storage.conf` 生成 `compose.storage.yaml`；
4. 域名模式下，构建带 DNS 插件的 Caddy 镜像；
5. 拉取镜像并启动全部服务，等待 Nextcloud 安装完成、状态变为健康；
6. 初始化 wg-easy：设置 HomeVault 需要的防火墙钩子和默认 AllowedIPs，然后删除初始密码文件；
7. 初始化 restic 备份仓库；
8. 显示**安装总结**。

### 6.4 安装总结：务必保存

总结里会有：

- 访问地址，例如 `https://192.168.1.10`；
- Nextcloud 管理员用户名（默认 `hvadmin`）和**初始密码**；
- IP 模式下：根证书的 SHA-256 指纹和导出路径；
- **restic 备份密码**；
- 路由器端口转发说明、VPN 管理界面地址；
- 下一步清单，包括手机设置清单。

> ⚠️ 管理员密码和 restic 密码**只显示这一次**。请马上存进密码管理器，restic 密码最好再抄一份在纸上，离线保存。

### 6.5 无人值守安装（进阶）

```bash
sudo ./hv install --non-interactive \
  --host 192.168.1.10 --lan-ip 192.168.1.10 \
  --data-dir /srv/homevault \
  --wg-host vpn.example.com --wg-port 34567 \
  --tls-mode internal
```

没有给出的项目会使用默认值。全部参数见 `./hv help`。

### 6.6 重新运行是安全的

在已经装好的系统上再次运行 `./hv install`，**不会**重新生成密码或覆盖数据。它会复用已有的 `.env` 和 `secrets/`，所以可以放心用来修改配置或升级 HomeVault 套件本身。

---

## 7. 硬盘角色：主数据 / 额外存储 / 备份目标

安装时（以及之后运行 `./hv storage list` 时），会显示一张硬盘表：

```text
挂载点        设备       文件系统  总容量   可用     物理磁盘  SSD/HDD  USB
/            nvme0n1p2  ext4      476 GB   401 GB   nvme0n1   SSD      否
/mnt/data1   sdb1       btrfs     3.6 TB   3.5 TB   sdb       HDD      否
/mnt/data2   sdc1       ext4      1.8 TB   0.3 TB   sdc       HDD      否
/mnt/backup  sdd1       ext4      4.5 TB   4.5 TB   sdd       HDD      是
```

"物理磁盘"一列表示分区属于哪块物理硬盘，同一块硬盘上的不同分区，这一列相同。

| 角色 | 数量 | 在 Nextcloud 里 | 建议 |
|---|---|---|---|
| **主数据** | 恰好 1 个 | 每个用户的"文件"，也是手机自动上传的目标 | 选容量最大、最健康的内置硬盘，例如上表的 `/mnt/data1` |
| **额外存储** | 0 个或多个 | 管理员挂载的"外部存储"文件夹，可设为只读或读写，可以只给某些用户或群组看 | 已有资料盘，例如 `/mnt/data2/影视资料`（只读） |
| **备份目标** | 1 个 | 不显示 | **必须**在与主数据不同的物理硬盘上，例如上表的 `/mnt/backup` |

安装程序会在这些情况给出警告：

- ⚠️ 主数据放在**系统盘**上（系统盘坏了或重装系统会有风险，空间也往往不够）；
- ⚠️⚠️ 备份目标和主数据，或者和某个读写的额外存储，在**同一块物理硬盘**上。一块硬盘坏了，数据和备份会一起丢，这是**严重警告**；
- ⚠️ 选了 FAT32/exFAT（没有权限控制，FAT32 单个文件最大 4 GB）；
- ⚠️ 主数据放在 **USB 硬盘**上（容易松动、断电或被误拔）。

### 7.1 以后管理额外存储

额外存储的配置保存在 `storage.conf`，每行一个：

```text
# 名称|主机路径|rw或ro|是否备份(yes/no)|可见用户(空=所有用户; 逗号分隔; @开头为群组)
照片归档|/mnt/data2/照片归档|rw|yes|
影视资料|/mnt/data2/影视资料|ro|no|@family
```

| 命令 | 作用 |
|---|---|
| `sudo ./hv storage list` | 显示硬盘表和已配置的额外存储 |
| `sudo ./hv storage add` | 交互式添加一个额外存储 |
| `sudo ./hv storage remove <名称>` | 删除一个额外存储（只从 Nextcloud 里取消挂载，**不会删除**硬盘上的文件） |
| `sudo ./hv storage apply` | 按 `storage.conf` 重新生成配置、重建容器并同步 Nextcloud 里的挂载 |

- 读写（`rw`）存储需要让容器里的 www-data（uid 33）有写权限。`apply` 会**先询问你**，再用 `setfacl` 给这个目录加上 uid 33 的读写权限，不会改动原有的属主。
- 在 Nextcloud 之外（例如直接在主机上）往额外存储里拷了文件，Nextcloud 访问这个目录时会自动发现变化。想立刻全部显示，可以运行 `sudo ./hv occ files:scan --all`。
- "是否备份"设为 `yes` 的存储，会被一起放进 restic 备份。

---

## 8. 主机防火墙

```bash
sudo ./hv firewall --apply    # 应用（可重复执行）
sudo ./hv firewall --show     # 查看
```

它会：

1. 在 Docker 的 `DOCKER-USER` 链里挂一条 `HOMEVAULT` 链：发往 HTTP/HTTPS/管理端口的**新 TCP 连接**，来源 IPv4 不在 `HV_ALLOWED_CIDRS` 里的一律丢弃。规则由 `homevault-firewall.service` 在每次 Docker 启动后自动恢复。
2. 如果装了 ufw：设置默认拒绝所有入站，**只允许局域网访问 SSH**。

为什么只配 ufw 不够（Docker 发布的端口会绕过 ufw），详见 [docs/01-架构与安全.md](01-架构与安全.md) §3.4。

⚠️ 应用后，只有局域网内的设备能 SSH 到这台主机。外出时要远程管理，请先连上 VPN，并且 VPN 访问范围需要是 `full`；或者回家再处理。

---

## 9. 路由器端口转发

在路由器管理页面的"端口转发 / 虚拟服务器 / NAT"里添加**一条**规则：

| 项目 | 填写 |
|---|---|
| 协议 | **UDP**（只要 UDP） |
| 外部端口 | `WG_PORT`（安装总结里显示的端口，例如 `34567`） |
| 内部 IP | `HV_LAN_IP`（例如 `192.168.1.10`） |
| 内部端口 | 同一个 `WG_PORT` |

⚠️ 只转发这一个 UDP 端口。**不要**转发 443/80/8443，**不要**开 DMZ。

如果光猫负责拨号（路由模式），要么把光猫改成桥接模式，让自己的路由器拨号；要么在光猫上也设置同样的转发。具体做法，以及如何检查端口是否通、怎样设置 DDNS，见 [docs/04-VPN与DDNS.md](04-VPN与DDNS.md)。

---

## 10. 首次登录和二步验证

1. **IP 模式先装根证书。** 在你要用来登录的电脑上安装 HomeVault 根证书：

   ```bash
   sudo ./hv ca --export /tmp/homevault-ca.crt
   ```

   命令会显示证书的 SHA-256 指纹，以及 Windows、macOS、Linux、安卓的安装方法。把文件拷到电脑上，装进系统的"受信任的根证书颁发机构"，装好后核对指纹。

2. 浏览器打开 `https://HV_HOST`（例如 `https://192.168.1.10`），用 `hvadmin` 和安装总结里的初始密码登录。

3. **绑定二步验证（强制）。** 第一次登录会要求设置 TOTP：用手机上任意一个身份验证器 App 扫描二维码，输入 6 位验证码。

4. **保存备用码。** 进入右上角头像 → **个人设置 → 安全**，生成"备用码"（backup codes），打印或抄下来离线保存。手机丢了、身份验证器没了，可以用它登录。

5. 可选：在同一页面把管理员密码改成你自己的强密码（至少 12 位），存进密码管理器。

6. **VPN 管理界面（wg-easy）。** 运行 `sudo ./hv vpn`，它会显示管理地址（`https://HV_HOST:8443`）、用户名，以及密码保存在哪里。登录后，立刻在右上角账户菜单里**启用二步验证**。wg-easy 没有登录频率限制，二步验证很重要。

7. 在 wg-easy 里为每台手机或电脑创建一个客户端，扫码导入。详见 [docs/04-VPN与DDNS.md](04-VPN与DDNS.md) 和 [docs/05-安卓手机备份.md](05-安卓手机备份.md)。

---

## 11. 创建家庭成员账户

```bash
# 普通成员，配额 500 GB
sudo ./hv user add mama --display-name "妈妈" --quota 500GB
sudo ./hv user add xiaoming --display-name "小明" --quota 200GB
# 另一位管理员（请谨慎）
sudo ./hv user add baba --display-name "爸爸" --admin
# 查看所有用户
sudo ./hv user list
```

- 用户名建议只用英文字母和数字（登录时要输入）；中文名字放在 `--display-name` 里。
- 新用户的初始密码**只显示一次**，请当面交给家人。家人第一次登录时，也必须绑定二步验证。
- 家人忘记密码：`sudo ./hv user reset-password <用户名>`；手机换了、身份验证器丢了：`sudo ./hv user reset-2fa <用户名>`，下次登录时重新绑定。
- 管理员能管理用户、重置二步验证，请只给真正需要的人管理员权限。

然后照着 [docs/05-安卓手机备份.md](05-安卓手机备份.md) 给每个人的手机设置自动上传。

---

## 12. 设置定时备份

安装时已经初始化了备份仓库。现在把每晚的自动备份打开：

```bash
sudo ./hv schedule-backup                 # 使用 .env 中的 HV_BACKUP_TIME（默认 03:30）
sudo ./hv schedule-backup --time 04:00    # 或指定时间
systemctl list-timers homevault-backup.timer
```

这会安装 systemd 定时器 `homevault-backup.timer`。它设置了 `Persistent=true`：备份时间点主机正好关着的话，下次开机后会补做一次。

建议现在手动做第一次完整备份。第一次数据多，会花几个小时：

```bash
sudo ./hv backup
journalctl -u homevault-backup.service -n 50     # 之后查看定时备份的日志
```

恢复单个文件、整机灾难恢复、异地备份，见 [docs/07-备份与恢复.md](07-备份与恢复.md)。

---

## 13. 体检：`./hv doctor`

```bash
sudo ./hv doctor
```

每一项会显示 ✔（正常）或 ✘（有问题），并附上处理建议。主要检查：

| 检查项 | ✘ 时怎么办 |
|---|---|
| 容器都在运行且健康 | `sudo ./hv status`、`sudo ./hv logs app` 查看原因 |
| 发布的端口只绑定在指定的 IPv4 地址上 | 检查 `.env` 中的 `HV_BIND_IP`，然后 `sudo ./hv up` |
| 防火墙规则存在 | `sudo ./hv firewall --apply` |
| 强制二步验证、`token_auth_enforced`、公开链接设置 | `sudo ./hv harden` |
| `occ status`、`occ setupchecks` 摘要 | 按提示处理；也可以在网页的 **管理设置 → 概览** 查看 |
| 每块用到的硬盘剩余空间（低于 10% 警告） | 清理文件、调整配额或加硬盘，见 [docs/08-日常运维与升级.md](08-日常运维与升级.md) |
| 上次备份时间（超过 48 小时警告） | `sudo ./hv backup` 手动跑一次，查看 `journalctl -u homevault-backup.service` |
| TLS 证书有效期 | `sudo ./hv logs caddy` 查看续期错误 |
| `secrets/` 和 `.env` 的权限 | 按提示修正 |
| 局域网 IP 没有变化 | 见 [docs/08-日常运维与升级.md](08-日常运维与升级.md)"更换局域网 IP" |

全部 ✔ 后，部署就完成了。日常维护看 [docs/08-日常运维与升级.md](08-日常运维与升级.md)。

---

## 14. 可选组件

- **DDNS**：`sudo ./hv ddns setup`、`sudo ./hv ddns status`，见 [docs/04-VPN与DDNS.md](04-VPN与DDNS.md)。
- **硬盘健康监控（Scrutiny）**：见 [docs/08-日常运维与升级.md](08-日常运维与升级.md)"硬盘健康"。

## 15. 常用命令速查

| 命令 | 作用 |
|---|---|
| `sudo ./hv status` | 查看各服务状态 |
| `sudo ./hv logs [服务名]` | 查看日志，服务名如 `app`、`caddy`、`db`、`wg-easy` |
| `sudo ./hv up` / `down` / `restart` | 启动 / 停止 / 重启全部服务（会自动带上正确的配置文件和 profile） |
| `sudo ./hv occ <参数>` | 执行 Nextcloud 的 occ 命令 |
| `sudo ./hv harden` | 重新应用安全加固并显示关键设置 |
| `sudo ./hv update` | 备份后更新镜像（同一大版本内） |
| `sudo ./hv doctor` | 体检 |

⚠️ 请用 `./hv up/down`，**不要**直接用 `docker compose up`：HomeVault 每次都要带上正确的配置文件组合（`compose.yaml`、`compose.acme.yaml`、`compose.storage.yaml`）和 profile，并在启动前重新计算派生设置。

---

## 来源 / 参考

版本信息截至 2026-09：

- Docker Engine 在 Debian 上的安装：<https://docs.docker.com/engine/install/debian/>；在 Ubuntu 上的安装：<https://docs.docker.com/engine/install/ubuntu/>
- 阿里云 Docker CE 镜像源：<https://mirrors.aliyun.com/docker-ce/>
- Docker 端口发布（Engine 28 起修复了本机端口可被同网段访问的问题）：<https://docs.docker.com/engine/network/port-publishing/>
- Docker 与防火墙：<https://docs.docker.com/engine/network/packet-filtering-firewalls/>
- DaoCloud 公共镜像加速（前缀与 registry-mirrors 注意事项）：<https://github.com/DaoCloud/public-image-mirror>
- goproxy.cn：<https://github.com/goproxy/goproxy.cn>
- btrfs 校验和与 scrub：<https://btrfs.readthedocs.io/>
- btrfsmaintenance（定期 scrub 建议）：<https://github.com/kdave/btrfsmaintenance>
- cryptsetup（LUKS2）：<https://gitlab.com/cryptsetup/cryptsetup>
- crypttab 与 systemd-cryptenroll：<https://www.freedesktop.org/software/systemd/man/latest/crypttab.html> · <https://www.freedesktop.org/software/systemd/man/latest/systemd-cryptenroll.html>
- Nextcloud 官方 Docker 镜像：<https://github.com/nextcloud/docker>
- Nextcloud 外部存储（Local）：<https://docs.nextcloud.com/server/latest/admin_manual/configuration_files/external_storage/local.html>
- wg-easy v15：<https://github.com/wg-easy/wg-easy>
- restic：<https://restic.readthedocs.io/>
