# 04 · VPN 与 DDNS

HomeVault 的网页服务**不对公网开放**。人在外面时，手机和笔记本先通过 WireGuard VPN "回到家里"，然后照常访问 `https://HV_HOST`。本文讲这条路怎么打通：确认公网 IP、设置路由器转发、配置动态域名（DDNS）、在服务器上管理 VPN 设备，以及排查"在家连不上""换了 IP 连不上"这类常见问题。

相关文档：[docs/01-架构与安全.md](01-架构与安全.md) · [docs/02-Linux部署.md](02-Linux部署.md) · [docs/03-Windows部署.md](03-Windows部署.md) · [docs/05-安卓手机备份.md](05-安卓手机备份.md) · [docs/06-电脑使用.md](06-电脑使用.md) · [docs/09-常见问题.md](09-常见问题.md)

> 本文命令约定：Linux 在 HomeVault 目录下执行 `sudo ./hv <命令>`；Windows 在**以管理员身份运行**的 PowerShell 中，于 HomeVault 目录下执行 `.\windows\hv.ps1 <命令>`。

---

## 0. 先看懂：外出时手机是怎么连回家的

```text
① 手机查询 WG_HOST（例如 vpn.example.com）
     公共 DNS 回答：1.2.3.4 —— 家里当前的公网 IP（由 ddns-go 或路由器自动更新）

② 手机 ──WireGuard 加密数据包（UDP）──▶ 1.2.3.4:WG_PORT
     └▶ 光猫 / 路由器（只转发这一个 UDP 端口）
          └▶ HomeVault 主机上的 WireGuard（wg-easy 或 WireGuard for Windows）

③ 手机在隧道里访问 https://HV_HOST（例如 https://192.168.1.10）
     └▶ Caddy（HTTPS）──▶ Nextcloud
```

这里有**两个不同的地址**，请不要混淆：

| 名称 | 作用 | 例子 | 解析到 |
|---|---|---|---|
| `WG_HOST` | VPN 的"门牌号"，手机用它找到你家 | `vpn.example.com`（DDNS 域名），或者直接写公网 IP | 家里当前的**公网 IPv4**（会变） |
| `HV_HOST` | Nextcloud 的访问地址，在家和在外**都用这一个** | IP 模式：`192.168.1.10`；域名模式：`cloud.example.com` | 主机的**局域网 IP**（固定不变） |

- 在家时，手机直接访问 `HV_HOST`，不需要 VPN。
- 在外时，VPN 客户端配置里的 AllowedIPs 包含 `HV_LAN_IP/32`，所以发往 `HV_HOST` 的流量会自动走进隧道；其他上网流量照常直连，不经过家里（这叫**分流**，见 [§5.1](#51-分流只有去家里的流量走隧道)）。
- 路由器上**只开放一个 UDP 端口**。没有正确密钥的数据包，WireGuard 一概不回应，外人扫描不到任何服务。

### 整体步骤

| 步骤 | 做什么 | 本文位置 |
|---|---|---|
| 1 | 确认家里宽带有公网 IPv4 | [§1](#1-确认你有公网-ipv4) |
| 2 | 光猫 / 路由器只转发 UDP `WG_PORT` | [§2](#2-光猫和路由器只转发一个-udp-端口) |
| 3 | 设置 DDNS，让 `WG_HOST` 始终指向家里的公网 IP | [§3](#3-ddns让域名跟着家里的-ip-走) |
| 4 | 服务器端 VPN：Linux 用 wg-easy，Windows 用 WireGuard for Windows | [§4](#4-服务器端管理-vpn-设备) |
| 5 | 为每台设备生成配置并导入 | [§4](#4-服务器端管理-vpn-设备)、[docs/05-安卓手机备份.md](05-安卓手机备份.md) |
| 6 | 用 4G 实际测试一次 | [§2.3](#23-检查转发是否生效) |

---

## 1. 确认你有公网 IPv4

外出时想连回家，你家宽带必须有**公网 IPv4 地址**（动态的也可以，DDNS 会解决变化的问题）。很多家庭宽带默认只有"内网地址"（运营商级 NAT，简称 CGNAT），这时外面的数据包根本进不来，端口转发设置得再对也没用。

### 1.1 第一步：看路由器 WAN 口的 IP

登录你**自己路由器**的管理页面（常见地址 `192.168.1.1`、`192.168.0.1`、`192.168.31.1` 等，路由器背面标签上有写），找到"上网设置 / WAN 口状态 / 互联网"，记下 **WAN IP**。

### 1.2 第二步：查"外面看到的"出口 IP

在家里任意一台设备上查询出口 IP：

```bash
# Linux / macOS
curl https://4.ipw.cn
```

```powershell
# Windows（注意是 curl.exe，PowerShell 里的 curl 是另一个命令的别名）
curl.exe https://4.ipw.cn
```

手机连着家里 Wi-Fi 时，也可以直接用浏览器打开 `https://4.ipw.cn`。

### 1.3 对比结果

| 情况 | 说明 | 结论 |
|---|---|---|
| WAN IP 和出口 IP **相同** | 路由器直接拿到了公网 IP | ✔ 有公网 IPv4，继续 [§2](#2-光猫和路由器只转发一个-udp-端口) |
| WAN IP 在 `100.64.0.0` – `100.127.255.255` 之间（即 `100.64.0.0/10`） | 运营商级 NAT（CGNAT） | ✘ 没有公网 IPv4，见 [§1.4](#14-没有公网-ip给运营商打电话) |
| WAN IP 是 `192.168.x.x`、`10.x.x.x` 或 `172.16.x.x`–`172.31.x.x` | 你的路由器接在光猫后面，光猫在负责拨号（"双重 NAT"） | 登录**光猫**管理页面看它的 WAN IP，再按本表判断一次；光猫设置见 [§2.1](#21-先弄清楚谁在拨号光猫还是路由器) |
| WAN IP 是公网地址，但和出口 IP **不同** | 运营商还做了一层 NAT，或者你有多条线路 | 大概率进不来，按 [§1.4](#14-没有公网-ip给运营商打电话) 联系运营商确认 |

> 公网 IP 通常过一段时间就会变（光猫重启、定期重新拨号等），这正是需要 DDNS 的原因。

### 1.4 没有公网 IP：给运营商打电话

| 运营商 | 客服电话 |
|---|---|
| 中国电信 | 10000 |
| 中国联通 | 10010 |
| 中国移动 | 10086 |

可以这样说："您好，我家宽带目前是内网地址，想申请改为**动态公网 IPv4 地址**。"

- 社区经验：电信一般能开通；联通部分地区可以；移动大多不提供。以当地客服答复为准。
- 开通后通常需要**重启光猫**（重新拨号）才会拿到公网 IP，之后按 [§1.1](#11-第一步看路由器-wan-口的-ip)–[§1.3](#13-对比结果) 再确认一次。
- 家庭宽带的用户协议一般不允许架设对外服务的"服务器"。HomeVault 只开放一个 UDP 端口，只给自家设备使用，但请你自己了解并遵守所用宽带的条款。

实在拿不到公网 IPv4，请看 [§9 没有公网 IPv4 时的替代方案](#9-没有公网-ipv4-时的替代方案)。

---

## 2. 光猫和路由器：只转发一个 UDP 端口

### 2.1 先弄清楚谁在拨号：光猫还是路由器

| 方式 | 说明 | 端口转发要设几次 |
|---|---|---|
| **A. 光猫桥接 + 自己的路由器拨号**（推荐） | 光猫只负责"光转电"，由你的路由器用宽带账号密码拨号（PPPoE），路由器 WAN 口直接拿到公网 IP | 只在路由器上设 1 次 |
| **B. 光猫路由模式**（很多家庭的默认状态） | 光猫自己拨号，你的路由器接在光猫下面 | 两级都要设：光猫把 UDP `WG_PORT` 转给路由器的 WAN IP，路由器再转给 `HV_LAN_IP` |
| **C. 只有光猫，主机直接插在光猫上** | 光猫拨号，同时当路由器用 | 在光猫上设 1 次 |

改成桥接模式需要：

- 宽带账号和密码（找运营商要，或看装机单）；
- 光猫的管理员（"超级管理员"）权限——通常只有运营商有。最省事的办法是打客服电话，请他们远程或上门把光猫改成桥接。

⚠️ **任何时候都不要使用 DMZ（"DMZ 主机"）功能。** DMZ 会把**所有端口**都转发到主机上，而 Docker 发布的端口会绕过主机上的 ufw 防火墙（原因见 [docs/01-架构与安全.md](01-架构与安全.md) §3.4）。HomeVault 只需要一个 UDP 端口。

### 2.2 添加端口转发规则

在路由器（或光猫）管理页面里找"端口转发 / 虚拟服务器 / 端口映射 / NAT 设置"，添加**一条**规则：

| 项目 | 填写 |
|---|---|
| 协议 | **UDP**（只选 UDP，不要选 "TCP+UDP" 或 "全部"） |
| 外部端口 | `WG_PORT`，例如 `34567` |
| 内部 IP | `HV_LAN_IP`，例如 `192.168.1.10`（光猫路由模式下的第一级，填你路由器的 WAN IP） |
| 内部端口 | 同一个 `WG_PORT` |

- `WG_PORT` 是安装时在 20000–60000 之间随机选出的端口，安装总结里有显示，也可以在 `.env` 里查到。用不常见的高位端口，可以避开大量针对默认端口 51820 的扫描。
- ⚠️ **不要**转发 TCP 443、80、8443、9443 或任何其他端口。网页服务只在局域网和 VPN 里使用。
- 主机的局域网 IP 必须固定：在路由器的"DHCP 静态分配 / IP 与 MAC 绑定"里给主机固定一个地址，见 [docs/02-Linux部署.md](02-Linux部署.md) 和 [docs/03-Windows部署.md](03-Windows部署.md)。

> 社区里有部分网络对 WireGuard 的 UDP 流量有干扰或限速的反馈（多见于跨境线路）。如果某个端口长期不稳定，可以换一个端口。换端口要同时修改服务器（`.env` 里的 `WG_PORT` 以及 VPN 服务端的监听端口）、路由器转发规则和每台设备的客户端配置（重新导入），所以确定下来后尽量不要改。

### 2.3 检查转发是否生效

网上的"端口检测"工具大多只能测 TCP，测不了 WireGuard 用的 UDP。最可靠的办法是实际连一次：

1. 先按 [§4](#4-服务器端管理-vpn-设备) 为手机生成一个 VPN 配置，并导入手机（步骤见 [docs/05-安卓手机备份.md](05-安卓手机备份.md)）。
2. 手机**关掉 Wi-Fi**，只用 4G/5G。
3. 打开 VPN，等几秒，在 VPN App 里查看这条隧道的**上次握手时间**（WireGuard App 里的名称就是"上次握手时间"）。
4. 能看到"几秒之前"，说明整条路通了 ✔。一直是空的，按 [§10 排错](#10-排错) 检查。

服务器端也能看到握手：

- **Linux：** wg-easy 管理界面的客户端列表会显示每台设备最近是否连接、收发流量。
- **Windows：** `.\windows\hv.ps1 vpn list`（以管理员身份运行时显示"最近握手"一列）。
- **两个平台：** 管理面板的 **VPN** 页（`https://HV_HOST:9443`）显示每台设备是否在线、最近握手时间和流量。这些数据由主机上的定时任务写入，最多有几分钟延迟（Linux 每 5 分钟，Windows 每 2 分钟）。

---

## 3. DDNS：让域名跟着家里的 IP 走

公网 IP 会变。`WG_HOST` 如果直接写 IP，IP 一变，所有手机就都连不上了。所以推荐：用一个域名（例如 `vpn.example.com`）作为 `WG_HOST`，再由 DDNS 程序在 IP 变化时自动更新这个域名的 A 记录。

> 域名模式下，你的域名可能有两条记录：`vpn.example.com` 指向**公网 IP**（给 VPN 用，由 DDNS 更新），`cloud.example.com` 指向**局域网 IP**（给 Nextcloud 用，固定不变）。**不要**让 DDNS 去改 `HV_HOST` 那条记录。

### 3.1 两种做法，选一种

| 做法 | 优点 | 适合 |
|---|---|---|
| **路由器自带 DDNS** | 路由器直接知道 WAN 口 IP，反应最快；不依赖 HomeVault 主机 | 路由器支持你所用的 DNS 服务商（很多路由器支持阿里云、DNSPod、花生壳等） |
| **HomeVault 的 ddns-go**（可选组件，profile `ddns`） | 一条命令设置；支持 5 家国内外 DNS 服务商；不开网页界面，更安全 | 路由器没有合适的 DDNS 功能 |

**使用 HomeVault 的 ddns-go：**

```bash
# Linux
sudo ./hv ddns setup      # 按提示选择 DNS 服务商、输入域名和 API 密钥
sudo ./hv ddns status     # 查看运行状态、当前公网 IP 和域名解析结果
```

```powershell
# Windows
.\windows\hv.ps1 ddns setup
.\windows\hv.ps1 ddns status
```

`ddns setup` 会：

1. 生成 `secrets/ddns-go.yaml`（完整的 ddns-go 配置，包含 API 密钥，请勿外传），并在 `.env` 里写入 `HV_DDNS_ENABLED=true`、`HV_DDNS_PROVIDER`、`HV_DDNS_DOMAIN`；
2. 启动 `ddns-go` 容器：以 `-noweb` 方式运行（**没有网页界面**），每 300 秒通过 `https://ddns.oray.com/checkip` 和 `https://4.ipw.cn` 检查一次公网 IPv4，发现变化就更新域名解析；
3. 如果 `WG_HOST` 原来是空的，直接改成这个域名；原来是一个 IP 时，Linux 也会**直接**改成这个域名并提醒你，Windows 会先询问（默认"是"）。

支持的 DNS 服务商（`HV_DDNS_PROVIDER`）和需要的密钥：

| 服务商 | `HV_DDNS_PROVIDER` | 需要填写 |
|---|---|---|
| 阿里云（云解析 DNS） | `alidns` | AccessKey ID + AccessKey Secret |
| 腾讯云（DNSPod，API 3.0） | `tencentcloud` | SecretId + SecretKey |
| DNSPod（旧版 Token） | `dnspod` | ID + Token |
| Cloudflare | `cloudflare` | API Token |
| 华为云 | `huaweicloud` | Access Key Id + Secret Access Key |

> 注意区分：域名模式的**证书**（`HV_DNS_PROVIDER`）只支持 `alidns`、`tencentcloud`、`cloudflare` 三家；**DDNS**（`HV_DDNS_PROVIDER`）支持上表 5 家。两者可以用同一家服务商。

### 3.2 API 密钥：只给最小权限 ⚠️

DNS API 密钥能修改你整个域名的解析。一旦泄露，别人可以把你的域名指向任何地方。所以：

- **阿里云：** 在 RAM 访问控制里新建一个**子用户**，只授予云解析 DNS 相关的权限（例如系统策略 `AliyunDNSFullAccess`，或更严格的只允许管理解析记录的自定义策略），用这个子用户的 AccessKey。**绝不要**用主账号的 AccessKey。
- **腾讯云：** 在访问管理（CAM）里新建子用户，只授予 DNSPod 相关权限。
- **Cloudflare：** 创建 API Token 时选 "Edit zone DNS"（编辑区域 DNS）模板，"区域资源"只选这一个域名。不要用 Global API Key。
- **华为云：** 在 IAM 里新建用户，只授予云解析服务（DNS）相关权限。
- 密钥只保存在 `secrets/ddns-go.yaml` 里。不要截图、不要发到聊天工具。

### 3.3 IP 变化以后会发生什么

1. 运营商给你换了新的公网 IP；
2. ddns-go 最多 5 分钟内发现，并更新域名的 A 记录（路由器自带 DDNS 的间隔视型号而定）；
3. 各地 DNS 服务器上的旧记录还要等缓存（TTL）过期，一般几分钟到十几分钟；
4. **VPN 客户端要重新查询一次域名**，才会连到新 IP。各客户端的表现不同：

| 客户端 | 什么时候解析 `WG_HOST` | IP 变化后你要做什么 |
|---|---|---|
| **WG Tunnel**（安卓，推荐） | 启动时解析；并具备"动态 DNS 自动更新"功能，检测到服务器 IP 变化后自动更新对端地址，无需重启 | 通常什么都不用做 |
| **WireGuard 官方安卓 App** | 只在**打开隧道时**解析一次 | 把隧道**关掉再打开** |
| **WireGuard for Windows**（电脑客户端） | 只在隧道服务**启动时**解析一次 | 在 WireGuard 窗口里"断开"再"连接" |

> 设置 DDNS 之前已经生成的客户端配置，里面的 Endpoint 仍是旧的 IP，**不会自动改变**：
> - **Windows 服务端：** `ddns setup` 会提醒你用 `.\windows\hv.ps1 vpn qr <名称>` 重新生成二维码并重新导入。
> - **Linux 服务端（wg-easy）：** 在 wg-easy 管理界面的配置里把主机地址（Host）改成新域名，然后为每台设备重新下载配置或重新扫码导入。

---

## 4. 服务器端：管理 VPN 设备

**每台设备一个 VPN 客户端配置。** 不要把同一个配置导入两台设备：同一把密钥同时在线会互相"挤掉"，而且设备丢失时也无法单独撤销。

**设备名建议：** 只用英文字母、数字和 `-`，**不超过 15 个字符**，例如 `phone-mama`、`laptop-baba`。原因：

- WireGuard 安卓 App 的隧道名最多 15 个字符，只允许字母、数字和 `_ = + . -`；
- Linux 的 `vpn add` 允许字母、数字和 `. _ -`，最长 32 个字符；Windows 的 `vpn add` 与安卓 App 的限制相同（最长 15 个字符）。

### 4.1 Linux：wg-easy

安装时 HomeVault 已经自动完成了 wg-easy 的初始化：设置好监听端口、默认 DNS、默认 AllowedIPs（分流）、保活设置，以及"只能访问本机"的防火墙钩子，然后删除了初始密码文件。

**登录管理界面：**

```bash
sudo ./hv vpn            # 显示管理地址、用户名、密码文件位置、路由器转发说明
sudo ./hv vpn status     # 同上，并显示 wg-easy 容器状态
```

- 管理地址：`https://HV_HOST:HV_ADMIN_PORT`（默认 `https://HV_HOST:8443`），只能在局域网或 VPN 内打开；
- 用户名：`hvadmin`；密码保存在 `secrets/` 目录的文件里（`sudo ./hv vpn` 会告诉你具体位置）。

⚠️ **登录后立即启用二步验证。** wg-easy 没有登录频率限制，谁能打开这个页面，谁就可以反复猜密码：

1. 点右上角的账户菜单 → 账户（Account）；
2. 启用二步验证（TOTP），用身份验证器 App 扫码，输入 6 位验证码确认。

启用二步验证后，wg-easy 的 API 就不能用密码调用了，因此 `sudo ./hv vpn add` 会失败。这是正常的，改在网页上添加设备即可。`vpn list` 和 `vpn qr` 不依赖 API，仍然可用。

**添加一台设备：**

- **网页（推荐，启用二步验证后只能用这种方式）：** 点"新建客户端"（New Client），输入设备名 → 在客户端列表里点二维码图标，用手机 App 扫码；电脑则点下载按钮，得到 `.conf` 文件。
- **命令行（启用二步验证之前可用）：**

  ```bash
  sudo ./hv vpn add phone-mama     # 创建设备，在终端里显示二维码，配置保存到 clients/phone-mama.conf
  sudo ./hv vpn list               # 列出所有设备和它们的 ID
  sudo ./hv vpn qr 3               # 按 ID 重新显示某台设备的二维码
  ```

  ⚠️ `clients/<设备名>.conf` 里有这台设备的私钥。导入设备后请删除它。

**删除或停用一台设备：** 在 wg-easy 客户端列表里点这台设备的删除（或禁用）按钮。设备丢失时的完整步骤见 [docs/08-日常运维与升级.md](08-日常运维与升级.md) §10。

**忘记 wg-easy 密码或丢了二步验证：**

```bash
sudo ./hv vpn reset-password     # 生成新密码（同时清除二步验证），新密码写入原来的密码文件
```

**访问范围（`HV_VPN_LAN_ACCESS`）：** 默认 `host`，VPN 设备只能访问 HomeVault 主机。确实需要在外访问家里的其他设备（NAS、路由器管理页等）时才改成 `full`，风险说明见 [docs/01-架构与安全.md](01-架构与安全.md) §3.5。修改方法：

1. 在 `.env` 里设置 `HV_VPN_LAN_ACCESS=full`；
2. 运行 `sudo ./hv vpn finalize`。如果已经启用了二步验证，命令会打印需要在 wg-easy 网页上手动修改的内容（Allowed IPs 和 Hooks），照着改完后运行 `sudo ./hv vpn finalize --skip-api`；
3. 已经导入的设备配置不会自动更新，需要重新导入。

### 4.2 Windows：WireGuard for Windows 隧道服务

Windows 版不使用 wg-easy，而是由 `hv.ps1` 直接管理官方 WireGuard for Windows：

- 隧道服务名为 `WireGuardTunnel$homevault`，**开机自动启动，不需要登录**；
- 隧道网卡地址是 VPN 网段的第一个地址（默认 `10.99.77.1`）；
- 计划任务 `HomeVault-WeakHost` 负责开启"弱主机模式"，让 VPN 设备可以访问主机的局域网 IP（原理见 [docs/03-Windows部署.md](03-Windows部署.md) §10）；
- Windows 版不做 NAT 和转发，VPN 设备**只能访问这台电脑**，`HV_VPN_LAN_ACCESS=full` 在 Windows 上无效。

在**管理员** PowerShell 中：

```powershell
.\windows\hv.ps1 vpn status              # 隧道服务、弱主机模式、计划任务是否正常
.\windows\hv.ps1 vpn add phone-mama      # 添加设备：在浏览器里打开二维码页面
.\windows\hv.ps1 vpn list                # 列出所有设备、VPN 地址、最近握手时间
.\windows\hv.ps1 vpn qr phone-mama       # 重新显示某台设备的二维码
.\windows\hv.ps1 vpn remove phone-mama   # 删除设备（手机丢失时用）
```

`vpn add` 的过程：

1. 生成这台设备的密钥，写入服务端配置并重启隧道服务；
2. 在浏览器里打开一个**本地**二维码页面（二维码在本机生成，不经过任何网络服务），用手机扫码导入；
3. 扫完后回到 PowerShell 按回车，程序询问是否删除二维码页面文件（其中含私钥），直接回车就是删除；
4. 询问是否删除 `clients\phone-mama.conf`。**建议删除**：服务器不保存设备私钥，以后需要时用 `vpn qr` 重新生成（会换一把新密钥，旧配置随之失效，VPN 地址不变）。

也可以双击桌面上的"HomeVault 管理"，在菜单里选"添加手机VPN"或"VPN设备列表"。

---

## 5. 客户端配置逐行解读：分流、DNS、保活

一份 Linux（`host` 模式）设备配置大致如下（数值仅为示例）：

```ini
[Interface]
PrivateKey = （这台设备自己的私钥，不要外传）
Address = 10.99.77.2/32              # 这台设备在 VPN 里的地址
DNS = 223.5.5.5, 119.29.29.29        # HV_VPN_DNS

[Peer]
PublicKey = （服务器公钥）
PresharedKey = （预共享密钥，多一层保护）
AllowedIPs = 10.99.77.0/24, 192.168.1.10/32   # 分流：只有这些地址走隧道
Endpoint = vpn.example.com:34567     # WG_HOST:WG_PORT
# PersistentKeepalive 默认不写（等于 0，关闭）
```

### 5.1 分流：只有去家里的流量走隧道

| 服务端 | 访问范围 | 设备配置里的 AllowedIPs |
|---|---|---|
| Linux，`HV_VPN_LAN_ACCESS=host`（默认） | 只有 HomeVault 主机 | `HV_VPN_CIDR, HV_LAN_IP/32`，例如 `10.99.77.0/24, 192.168.1.10/32` |
| Linux，`HV_VPN_LAN_ACCESS=full` | 整个家庭局域网 | `HV_VPN_CIDR, HV_LAN_CIDR`，例如 `10.99.77.0/24, 192.168.1.0/24` |
| Windows | 只有这台电脑 | `<隧道地址>/32, HV_LAN_IP/32`，例如 `10.99.77.1/32, 192.168.1.10/32` |

好处：刷视频、微信等流量不绕道家里，**不耗家里的上行带宽，也更省电**；VPN 一直开着也不影响正常上网。

⚠️ **不要**把手机上的 AllowedIPs 改成 `0.0.0.0/0`（"全局代理"）。在 `host` 模式下，服务器会丢弃除 HomeVault 主机以外的所有转发流量，手机会立刻上不了网。WireGuard 官方 App 里的"排除局域网"选项只在 `0.0.0.0/0` 时才有意义，HomeVault 用不到。

### 5.2 DNS

- 默认 `HV_VPN_DNS=223.5.5.5,119.29.29.29`（两个国内公共 DNS）。wg-easy 自带的默认值是 Cloudflare 的 `1.1.1.1`，HomeVault 在安装时已经替换掉了。
- ⚠️ **不要**把 DNS 设成家里路由器的地址（例如 `192.168.1.1`）。在分流模式下，路由器地址不走隧道，在外面时这个查询会被发给你所在网络里的另一台 `192.168.1.1`，导致解析失败。
- 域名模式下，`HV_HOST`（例如 `cloud.example.com`）的公网 A 记录就是局域网 IP，任何公共 DNS 都能查到，在外面不需要特殊设置。

### 5.3 保活（PersistentKeepalive）

- 默认 `HV_VPN_KEEPALIVE=0`（关闭）。HomeVault 服务器有公网 IP，每次都是手机主动发起连接，所以通常不需要保活，而且关掉更省电。
- 如果出现"空闲一会儿后就连不上、要重开 VPN"，可能是所在网络的 NAT 把连接回收了。这时把**这台设备**的保活改成 `25` 秒：
  - 在手机 App 里编辑隧道，把"连接保活间隔"（Persistent keepalive）填 `25`；或者
  - 在 wg-easy 网页里编辑这个客户端，然后重新导入。
- 想让以后新建的设备都默认开启保活：在 `.env` 里设置 `HV_VPN_KEEPALIVE=25`。
  - Windows：之后 `vpn add` / `vpn qr` 生成的配置都会带上保活；
  - Linux：wg-easy 只在**创建设备时**复制这个值，已经存在的设备要逐个修改，新的默认值要在 wg-easy 网页的全局配置里调整。

---

## 6. 在家时：NAT 回流（hairpin）问题

**现象：** 在外面用 4G 一切正常；回到家、连上家里 Wi-Fi 以后，VPN 还开着，Nextcloud 反而打不开了。

**原因：** VPN 开着时，发往 `HV_LAN_IP` 的流量会走进隧道，而隧道要先连到 `WG_HOST`，也就是**家里的公网 IP**。手机在家里访问自家的公网 IP，需要路由器把数据包"绕回"内网，这叫 **NAT 回流**（NAT loopback / hairpin）。很多路由器和光猫不支持，于是握手失败，连带 Nextcloud 也访问不到。

**解决办法（任选一种）：**

| 办法 | 做法 | 推荐程度 |
|---|---|---|
| **在家自动关闭 VPN** | 用 **WG Tunnel** 的"自动隧道"功能：把家里的 Wi-Fi 名称（SSID）加入"可信 WiFi 名称"，连上家里 Wi-Fi 时隧道自动关闭，离开后自动打开。具体步骤见 [docs/05-安卓手机备份.md](05-安卓手机备份.md) | ★★★ 最省心 |
| **准备一个"家里"配置** | 适合用 WireGuard 官方 App、又想让 VPN 一直开着的人：再扫一次同一个二维码，隧道起名 `home`，编辑它，把"对端"（Endpoint）改成 `HV_LAN_IP:WG_PORT`（例如 `192.168.1.10:34567`）。在家用 `home`，出门切回原来那个；两个不要同时打开 | ★★ |
| **路由器开启 NAT 回流** | 有些路由器在高级设置里有"NAT 回流 / NAT 环回 / NAT loopback"选项，打开即可 | ★★（取决于路由器） |
| **家里的 DNS 把 `WG_HOST` 解析到局域网 IP** | 在路由器的"自定义 DNS / hosts"里添加 `vpn.example.com → 192.168.1.10` | ★（进阶） |
| **在家手动关闭 VPN** | 回家关、出门开 | ★（容易忘） |

> 其实在家里根本不需要 VPN：`HV_HOST` 在局域网里可以直接访问。上面的办法都是为了"忘了关也没关系"。

### 6.1 域名模式的特有问题：DNS 重绑定保护

域名模式下，`cloud.example.com` 的公网 A 记录是一个**私有地址**（例如 `192.168.1.10`）。有些路由器（例如 OpenWrt 默认开启的 `rebind_protection`）会把"公网域名解析到私有地址"的结果当作攻击丢弃，于是**在家里**打不开这个域名，在外面（用公共 DNS）却正常。

解决办法：

- 在路由器的 DNS 重绑定保护里把这个域名加入白名单。OpenWrt 示例：

  ```bash
  uci add_list dhcp.@dnsmasq[0].rebind_domain='cloud.example.com'
  uci commit dhcp
  /etc/init.d/dnsmasq restart
  ```

- 或者在路由器的"自定义 DNS / hosts"里直接添加 `cloud.example.com → 192.168.1.10`；
- 或者关闭重绑定保护（不推荐，它本身有防护作用）。

---

## 7. 网段冲突：为什么 `192.168.1.x` 不是好选择

家里局域网最常见的网段是 `192.168.1.0/24` 和 `192.168.0.0/24`，而酒店、咖啡店、朋友家、手机热点也大多用这两个网段。你在外面连着一个同网段的 Wi-Fi 时：

- `host` 模式下，VPN 只接管 `HV_LAN_IP/32` 这一个地址，比当地 Wi-Fi 的整段路由更精确，**通常仍然能用**，这也是 HomeVault 默认采用 `host` 模式的原因之一；
- `full` 模式下，VPN 要接管整个 `192.168.1.0/24`，会和当地网络打架：要么访问不到家里，要么当地网络（包括网关、认证页面）出问题。

HomeVault 自己用到的网段也要互相错开：

| 网段 | 默认值 | 说明 |
|---|---|---|
| 家庭局域网 `HV_LAN_CIDR` | 取决于你的路由器 | 推荐改成不常见的网段，例如 `192.168.77.0/24` |
| VPN 网段 `HV_VPN_CIDR` | `10.99.77.0/24` | 故意避开 wg-easy 和 OpenVPN 示例常用的 `10.8.0.0/24` |
| 容器前端网络 `HV_FRONTEND_SUBNET` | `172.31.250.0/24` | 不能和家庭局域网、VPN 网段重叠 |

**建议：**

- **还没安装 HomeVault：** 先在路由器的"局域网（LAN）设置"里把路由器地址改成例如 `192.168.77.1`、子网掩码 `255.255.255.0`，重启路由器，所有设备重新获取地址后，再给主机固定 IP 并安装。
- **已经安装：** 改局域网 IP 会影响访问地址、证书和所有设备配置，请按 [docs/08-日常运维与升级.md](08-日常运维与升级.md) §8"更换局域网 IP 或域名"操作。只用 `host` 模式的话，不改也基本没问题。

---

## 8. 电脑也可以用 VPN

笔记本外出时同样用 WireGuard 连回家，然后用 Nextcloud 桌面客户端同步。安装 WireGuard 客户端、导入配置、在家时关闭 VPN 等内容见 [docs/06-电脑使用.md](06-电脑使用.md)。

---

## 9. 没有公网 IPv4 时的替代方案

| 方案 | 思路 | 注意事项 |
|---|---|---|
| **只在家里备份**（最简单） | 手机不装 VPN。Nextcloud App 的自动上传会等手机回到家、连上 Wi-Fi 时再上传 | 出门几天，照片要等回家才备份；其余功能完全正常 |
| **Tailscale / Headscale** | 基于 WireGuard 的组网工具，能穿透 NAT，不需要公网 IP。Headscale 是可以自己部署的开源控制服务器 | 官方协调服务器和中继在境外，在国内可能连接慢或不稳定；自建 Headscale 和中继需要一台有公网 IP 的云服务器 |
| **ZeroTier** | 类似的虚拟局域网工具，也能穿透 NAT | 同样依赖境外根服务器，国内体验不稳定；可以自建，但需要云服务器和一定的动手能力 |

使用这类工具时的建议：

- **保持"一个地址走天下"**：在 HomeVault 主机上把这类工具设为"子网路由"，只发布 `HV_LAN_IP/32` 这一个地址。这样手机仍然访问原来的 `https://HV_HOST`，Nextcloud App 不需要改地址。
- Tailscale 分配给设备的地址在 `100.64.0.0/10` 范围内。HomeVault 的 Caddy 来源过滤默认已经包含这个网段（`HV_ALLOWED_CIDRS` 默认值为 `private_ranges 100.64.0.0/10`）。
- 用了第三方组网工具，你就信任了它的协调服务器。请在它的访问控制（ACL）里只允许自家设备访问 HomeVault 主机的 HTTPS 端口。
- 这些工具不在 HomeVault 的自动化范围内，需要你按各自的官方文档安装和维护。

---

## 10. 排错

先在手机 VPN App 里看这条隧道的**上次握手时间**，这是最重要的线索。

| 现象 | 可能原因 | 怎么办 |
|---|---|---|
| **握手一直没有成功**（上次握手时间为空） | ① 端口转发没设好：协议选了 TCP、端口号不一致、内部 IP 不是 `HV_LAN_IP`；② 光猫在拨号，只在路由器上设了转发；③ 其实没有公网 IP（CGNAT）；④ DDNS 还指向旧 IP；⑤ 手机在家里 Wi-Fi 上（NAT 回流） | ① 对照 [§2.2](#22-添加端口转发规则) 检查；② 按 [§2.1](#21-先弄清楚谁在拨号光猫还是路由器) 在光猫上也设转发，或改桥接；③ 按 [§1](#1-确认你有公网-ipv4) 确认；④ 运行 `ddns status`，对比域名解析结果和当前公网 IP；⑤ 关掉 Wi-Fi 用 4G 测试 |
| 握手一直不成功（续） | ⑥ 服务端 VPN 没运行 | Linux：`sudo ./hv vpn status` 查看 wg-easy 状态；Windows：`.\windows\hv.ps1 vpn status` 查看隧道服务，并用 `.\windows\hv.ps1 firewall --show` 确认防火墙规则存在（没有就运行 `.\windows\hv.ps1 firewall --apply`） |
| **握手成功，但打不开 Nextcloud** | ① 手机上的地址不是 `HV_HOST`（例如写成了公网域名 `WG_HOST`，或写错了端口）；② AllowedIPs 里没有 `HV_LAN_IP/32`（手动改过配置）；③ Windows：弱主机模式没生效；④ IP 模式：手机没装根证书，浏览器显示证书错误 | ① 用安装总结或 `status` 里显示的访问地址；② 重新导入配置；③ `.\windows\hv.ps1 vpn status` 检查 Weak Host，详见 [docs/03-Windows部署.md](03-Windows部署.md) §10；④ 见 [docs/05-安卓手机备份.md](05-安卓手机备份.md) 安装证书一节 |
| **在家 Wi-Fi 上打不开，4G 却正常** | NAT 回流（VPN 在家也开着）；域名模式下的 DNS 重绑定保护 | 见 [§6](#6-在家时nat-回流hairpin问题) 和 [§6.1](#61-域名模式的特有问题dns-重绑定保护) |
| **家里 Wi-Fi 正常，4G 不行** | 家里本来就不走 VPN，所以这说明 VPN 这条路没通 | 按"握手一直没有成功"一行检查 |
| **4G 正常，某个外面的 Wi-Fi 不行** | 该网络屏蔽了 UDP 或这个端口；需要先网页认证的 Wi-Fi 还没登录；网段冲突（`full` 模式） | 先完成 Wi-Fi 的网页认证；换用 4G；长期有问题可考虑换 `WG_PORT`（见 [§2.2](#22-添加端口转发规则)）；网段问题见 [§7](#7-网段冲突为什么-1921681x-不是好选择) |
| **家里 IP 变了以后连不上** | 官方 WireGuard 客户端只在打开隧道时解析一次域名 | 把隧道关掉再打开；或改用 WG Tunnel。见 [§3.3](#33-ip-变化以后会发生什么) |
| **用一会儿就断，重开 VPN 才好** | 所在网络的 NAT 超时；或者手机系统把 VPN App 杀掉了 | 把这台设备的保活改成 25（[§5.3](#53-保活persistentkeepalive)）；防杀后台设置见 [docs/05-安卓手机备份.md](05-安卓手机备份.md) |
| **开着 VPN 就上不了网** | AllowedIPs 被改成了 `0.0.0.0/0`；DNS 被改成了家里路由器的地址；开启了"屏蔽未使用 VPN 的所有连接"或 WG Tunnel 的"锁定"模式 | 重新导入原始配置；关闭这些拦截选项。见 [§5.1](#51-分流只有去家里的流量走隧道)、[§5.2](#52-dns) |
| **小文件正常，大文件传到一半就卡住** | 路径上的 MTU 偏小，大数据包被丢弃 | 在手机 App 里编辑隧道，把 MTU 改为 `1280` 后重连试试 |
| **wg-easy 管理页面打不开** | 地址不对；不在局域网或 VPN 内；IP 模式下电脑没装根证书 | 用 `https://HV_HOST:8443`（端口见 `HV_ADMIN_PORT`）；根证书安装见 [docs/06-电脑使用.md](06-电脑使用.md) |
| **`sudo ./hv vpn add` 报错** | wg-easy 管理员已启用二步验证，API 不再接受密码调用 | 在 wg-easy 网页里点"新建客户端"添加设备（[§4.1](#41-linuxwg-easy)） |
| **Windows：`vpn add` 提示名称不合法** | 名称只能用英文字母、数字和 `_ = + . -`，最多 15 个字符 | 换一个名字，例如 `phone-mama` |

还是不行的话，运行体检命令，把带 ✘ 的项目逐一处理：`sudo ./hv doctor`（Windows：`.\windows\hv.ps1 doctor`）。更多问题见 [docs/09-常见问题.md](09-常见问题.md)。

---

## 来源 / 参考

版本信息截至 2026-09：

- wg-easy v15（当前 15.4.0）文档：无人值守初始化（`INIT_*`）、二步验证、客户端 Allowed IPs、钩子、CLI：<https://github.com/wg-easy/wg-easy/tree/master/docs/content>
- wg-easy 默认值（端口 51820、`10.8.0.0/24`、DNS `1.1.1.1`、AllowedIPs `0.0.0.0/0`、保活 0）：<https://github.com/wg-easy/wg-easy/blob/master/src/server/database/migrations/0001_classy_the_stranger.sql>
- WireGuard `wg(8)` 手册（PersistentKeepalive 默认关闭，NAT 后可设 25 秒）：<https://github.com/WireGuard/wireguard-tools/blob/master/src/man/wg.8>
- WireGuard 安卓 App（只在隧道启动时解析 Endpoint 域名）：<https://github.com/WireGuard/wireguard-android/blob/master/tunnel/src/main/java/com/wireguard/android/backend/GoBackend.java>
- WireGuard for Windows（隧道服务启动时解析 Endpoint；企业部署说明）：<https://github.com/WireGuard/wireguard-windows/blob/master/tunnel/service.go> · <https://github.com/WireGuard/wireguard-windows/blob/master/docs/enterprise.md>
- WG Tunnel（自动隧道、动态 DNS 处理、锁定模式）：<https://github.com/wgtunnel/android>
- ddns-go（v6.17.7；参数 `-noweb`、`-f`；支持的服务商）：<https://github.com/jeessy2/ddns-go>
- RFC 6598（运营商级 NAT 共享地址段 `100.64.0.0/10`）：<https://www.rfc-editor.org/rfc/rfc6598>
- OpenWrt dnsmasq 配置（`rebind_protection`、`rebind_domain`）：<https://github.com/openwrt/openwrt/blob/main/package/network/services/dnsmasq/files/dhcp.conf>
- OpenVPN：私有网段的选择（避开常见网段）：<https://openvpn.net/community-docs/numbering-private-subnets.html>
- Docker 端口发布与防火墙（发布的端口绕过 ufw）：<https://docs.docker.com/engine/network/packet-filtering-firewalls/>
- 家庭宽带申请公网 IP 的社区经验（二手资料）：<https://mi-d.cn/1590> · <https://blog.csdn.net/qq_15715889/article/details/146995672>
- 检查是否处于运营商 NAT 之后（二手资料）：<https://zhuanlan.zhihu.com/p/358316811>
