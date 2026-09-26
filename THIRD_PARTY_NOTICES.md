# 第三方软件声明 / Third-Party Notices

HomeVault 本身以 MIT 许可证发布（见 [LICENSE](LICENSE)）。它是一个**部署套件**：
仓库中只包含编排文件、配置、脚本与文档，下列上游项目在安装时由 Docker 从各自的官方镜像仓库拉取
（或由用户自行安装），**不随本仓库分发**，各自遵循其原有许可证。

HomeVault is MIT-licensed. It is a deployment kit: the upstream projects below are pulled as
container images from their official registries (or installed by the user) and are **not
redistributed** in this repository. Each remains under its own license.

## 随仓库分发的第三方代码 / Vendored code

| 文件 | 项目 | 版本 | 许可证 |
|---|---|---|---|
| `windows/vendor/qrcode.js` | [qrcode-generator](https://github.com/kazuhikoarase/qrcode-generator) by Kazuhiko Arase | 2.0.4 | MIT |

qrcode-generator 许可证全文：

```
MIT License

Copyright (c) 2009 Kazuhiko Arase

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

"QR Code" 是 DENSO WAVE INCORPORATED 的注册商标。

## 运行时使用的上游项目（容器镜像）/ Upstream projects used at runtime

| 组件 | 用途 | 镜像 | 许可证 |
|---|---|---|---|
| [Nextcloud Server](https://github.com/nextcloud/server) | 文件同步 / 自动上传 / WebDAV / CalDAV / CardDAV | `nextcloud:34-apache` | AGPL-3.0 |
| [Nextcloud Docker 镜像](https://github.com/nextcloud/docker) | 官方镜像（入口脚本与 hooks 机制） | 同上 | AGPL-3.0 |
| [PostgreSQL](https://www.postgresql.org/) | 数据库 | `postgres:18-alpine` | PostgreSQL License |
| [Redis](https://github.com/redis/redis) | 缓存与文件锁 | `redis:8-alpine` | RSALv2 / SSPLv1 / AGPLv3（三选一，Redis 8 起） |
| [Caddy](https://github.com/caddyserver/caddy) | HTTPS 反向代理、本地 CA | `caddy:2.11.4-alpine` | Apache-2.0 |
| [wg-easy](https://github.com/wg-easy/wg-easy) | WireGuard VPN 管理（Linux） | `ghcr.io/wg-easy/wg-easy:15` | AGPL-3.0 |
| [restic](https://github.com/restic/restic) | 加密备份 | `restic/restic:0.19.1` | BSD-2-Clause |
| [ddns-go](https://github.com/jeessy2/ddns-go) | 动态域名（可选） | `jeessy/ddns-go:v6.17.7` | MIT |
| [Scrutiny](https://github.com/AnalogJ/scrutiny) | 硬盘 S.M.A.R.T. 监控（可选） | `ghcr.io/analogj/scrutiny:v0.9.4-omnibus` | MIT |

### 域名模式下本地构建的 Caddy / Caddy built locally for DNS-01 (`caddy/Dockerfile`)

仅在 `HV_TLS_MODE=acme-dns` 时，由用户的机器从源码编译（`caddy:2.11.4-builder` + xcaddy），产物不随仓库分发：

| Go 模块 | 版本 | 许可证 |
|---|---|---|
| github.com/caddyserver/caddy/v2 | v2.11.4 | Apache-2.0 |
| github.com/caddy-dns/alidns（含 libdns/alidns） | v1.0.29 | MIT |
| github.com/caddy-dns/tencentcloud（含 libdns/tencentcloud） | v0.4.3 | MIT |
| github.com/caddy-dns/cloudflare（含 libdns/cloudflare） | v0.2.4 | Apache-2.0（libdns/cloudflare：MIT） |

## 文档中推荐、由用户自行安装的软件 / Software recommended in the docs

| 软件 | 用途 | 许可证 |
|---|---|---|
| [Nextcloud Android](https://github.com/nextcloud/android) | 手机自动上传 | GPL-2.0 |
| [Nextcloud Desktop](https://github.com/nextcloud/desktop) | 电脑同步客户端 | GPL-2.0 |
| [DAVx⁵](https://github.com/bitfireAT/davx5-ose) | 通讯录 / 日历同步 | GPL-3.0 |
| [WG Tunnel](https://github.com/zaneschepke/wgtunnel) | 安卓 WireGuard 客户端（按 Wi-Fi 自动连接） | MIT |
| [WireGuard for Android](https://github.com/WireGuard/wireguard-android) | 安卓 WireGuard 官方客户端 | Apache-2.0 |
| [WireGuard for Windows](https://github.com/WireGuard/wireguard-windows) | Windows 上的 VPN 服务端 | MIT |

## 致谢 / Acknowledgements

- Windows 数据目录权限检查的处理方式（`check_data_directory_permissions=false`）参考了
  [Nextcloud All-in-One](https://github.com/nextcloud/all-in-one)（AGPL-3.0）的做法；HomeVault 中的实现为独立编写。
- 反向代理与安全加固的配置项依据 Nextcloud 官方管理员文档。

所有商标归其各自所有者所有。All trademarks belong to their respective owners.
