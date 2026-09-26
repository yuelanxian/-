# HomeVault 安卓端（HomeVault 家庭归档）

一个很小的原生安卓应用：在手机上全屏打开 HomeVault **管理面板**（概览 / 存储 / 备份 / 日志 / VPN / 设置），
并能一键跳转到 **Nextcloud 应用**（看文件、自动备份照片）和 **VPN 应用**（WG Tunnel / WireGuard）。

> 照片、视频的自动备份仍然由 Nextcloud 官方应用的“自动上传”完成（见 `docs/05-安卓手机备份.md`）。
> 本应用负责“管理”：看服务器状态、硬盘用量、备份记录、日志，调整日志保留天数等。

## 功能

| 功能 | 说明 |
|---|---|
| 首次设置 | 填写管理面板地址（例如 `https://192.168.1.10:9443`），只接受 `https://`；没写端口时自动补上面板默认端口 9443；只保留“协议 + 地址 + 端口”（从浏览器复制来的 `/#/storage` 之类会被去掉） |
| 测试连接 | 用和正式访问完全相同的证书规则请求面板的 `/api/info`，确认对方**确实是 HomeVault 管理面板**（显示面板版本），并用中文说明其他结果：证书未安装、证书与地址不匹配、连不上（没开 VPN / 不在家里 Wi-Fi）、填成了 Nextcloud 或其他服务（例如 8443 的 VPN 管理页）的地址、面板暂时无响应、不是 HTTPS 端口等。面板报告的 Nextcloud 地址不是默认的 `https://同一主机`（443）时，自动填入“Nextcloud 网页地址” |
| 管理面板 | 全屏显示；返回键在面板内后退；加载进度条；加载失败时显示原因和“重试 / 打开 VPN / 更换服务器”按钮，从 VPN 应用切回来会自动重试 |
| 刷新 | 顶栏按钮 |
| 文件 | 打开 Nextcloud 应用（`com.nextcloud.client`）；没装时提示下载，或在浏览器打开 Nextcloud 网页版 |
| VPN | 依次尝试打开 WG Tunnel（`com.zaneschepke.wireguardautotunnel`）、官方 WireGuard（`com.wireguard.android`）；都没装时说明怎么安装和导入配置 |
| 更换服务器 / 关于 | 顶栏菜单；更换服务器时会清除旧服务器的登录状态和缓存（即使中途应用被系统杀掉，下次打开时也会先清除） |
| 下载 | 面板里的下载（日志、证书、APK 等）交给系统“下载管理器”，自动带上登录 Cookie（只对面板本身，不会发给同一台服务器上的其他端口）；Android 10 及以上保存到“下载（Download）”，Android 8/9 保存到 `Android/data/app.homevault.android/files/Download` |
| 证书错误 | **绝不忽略**。停止加载并弹出中文说明：如何下载并安装 HomeVault 根证书（按钮直接在浏览器中打开 `<面板地址>/ca.crt`，另一个按钮打开系统“安全”设置） |

其他：深色模式；自适应图标和 Android 13+ 主题图标；Android 13+ 预测性返回手势；Android 15+ 全面屏（edge-to-edge）适配。

## 系统要求

- Android 8.0（API 26）及以上。
- 华为 HarmonyOS NEXT（纯血鸿蒙）不能安装 APK：请直接用手机浏览器打开管理面板地址。

## 安装

任选一种：

1. **GitHub Release**：在本项目的 Releases 页面下载 `homevault-android.apk`（`homevault-android.apk.sha256` 是校验值）。
2. **从自己的服务器下载**：在服务器上运行 `hv android fetch`，把最新 APK 下载到 `state/app/homevault.apk`；
   之后用电脑浏览器打开管理面板 → 设置 →“安卓应用”，用手机扫描二维码即可（手机要在家里 Wi-Fi 或已连 VPN）。

安装时手机会提示“允许安装未知来源应用”，按提示给浏览器 / 文件管理器授权即可。

## 第一次使用

1. 手机连上**家里的 Wi-Fi**（在外面则先打开 VPN）。
2. 打开“HomeVault 家庭归档”，输入管理面板地址（服务器安装完成时显示，默认端口 9443），点 **测试连接**。
3. 如果提示“证书不受信任”（服务器用 IP 地址模式时第一次一定会这样）：点 **证书安装说明**，按步骤安装根证书：
   1. 点“下载根证书”，浏览器会打开 `https://服务器:9443/ca.crt`。浏览器提示“您的连接不是私密连接”是因为证书还没装，点“高级 → 继续前往”下载即可
      （也可以在服务器上用 `hv ca` 导出证书文件，再用数据线或聊天软件发到手机）。
   2. 设置 → 安全（或“安全与隐私 → 更多安全设置”）→ 加密与凭据 → 安装证书 → **CA 证书** → 仍然安装 → 选择刚下载的 `homevault-ca.crt`（在“下载”文件夹里）。
      各品牌手机菜单名称不同，可以在设置里搜索“证书”。
   3. 在“可信凭据 → 用户”（有的系统叫“受信任的凭据”）里可以查看这个证书，核对 SHA-256 指纹与服务器上 `hv ca` 显示的一致。
   4. 装好后 Nextcloud 应用和手机浏览器也会信任它。
4. 点 **保存并打开**，用 Nextcloud 管理员账号登录管理面板（只有 Nextcloud `admin` 组的成员能进入；需要两步验证）。
   如果面板让你在浏览器里完成 Nextcloud 登录，登录完成后切回本应用即可。

## 安全设计

- 只申请一个权限：`INTERNET`（联网）。不含 AndroidX 和任何第三方库，只用 Android 系统 API；除 Kotlin 标准库外 APK 里没有别的代码。
- 只允许 HTTPS：网络安全配置禁止明文 HTTP；信任“系统证书 + 用户安装的证书”（IP 模式下需要用户安装 HomeVault 根证书）。
- 证书错误一律 `cancel()`，从不 `proceed()`；“测试连接”也使用同样的证书检查。
- WebView：启用 JavaScript 和 DOM 存储（面板需要）；禁止访问本机文件和内容提供者；禁止混合内容；禁止第三方 Cookie；
  不注入任何 JavaScript 接口；拒绝网页申请定位、摄像头、麦克风；关闭 WebView 使用统计和 Safe Browsing（只访问你自己的服务器）。
- 只有与管理面板**同源**（协议 + 主机 + 端口完全相同）的页面在应用内打开，其他链接一律交给外部浏览器；`javascript:`、`file:`、`intent:` 等链接直接拦截。
- 更换服务器时清除 Cookie、网页存储和缓存；清除完成后才加载新地址（Cookie 不区分端口）。应用记录“当前网页数据属于哪个服务器”，
  即使更换服务器后进程被系统杀掉，下次启动也会先清除，并且不会恢复旧服务器的页面。
- 下载时只给与面板同源的地址附带会话 Cookie。
- 不参与系统备份和换机迁移（服务器地址和登录状态只留在这台手机上）。
- release 版启用 R8 压缩和混淆。

## 与管理面板（服务器端）的约定

供开发 `panel/` 的人参考：

- 应用的 User-Agent 末尾带有 `HomeVaultApp/<版本>`，面板可以据此隐藏“下载安卓端”之类的提示。
- “测试连接”请求公开接口 `GET /api/info`，只有返回 `"app":"homevault-panel"` 才算成功；显示其中的 `version`，
  并用 `nextcloud_url`（= `HV_PUBLIC_URL`）自动填写 Nextcloud 网页地址。认不出面板时再请求 `/status.php` 判断是不是 Nextcloud。
- 下载请使用普通的 `https` 链接并返回 `Content-Disposition: attachment`（由系统下载管理器带着会话 Cookie 去下载）；
  `blob:` / `data:` 形式的下载不支持。
- 与面板不同源的链接会在外部浏览器打开——包括 Nextcloud（默认 443 端口）上的 Login Flow v2 登录页。
  面板打开登录页后应持续轮询登录结果，用户在浏览器登录完成后切回应用即可继续。
- 面板提供 `/ca.crt`（HomeVault 根证书，仅证书）和 `/download/android`（`state/app/homevault.apk`）。

## 自己构建

需要 JDK 17 或更高版本、Android SDK（platform 36），首次构建需要能访问 Google Maven（`dl.google.com`）和 Maven Central：

```bash
cd android
./gradlew assembleDebug            # app/build/outputs/apk/debug/app-debug.apk
./gradlew lint testDebugUnitTest   # 代码检查 + 单元测试
./gradlew assembleRelease          # app/build/outputs/apk/release/app-release.apk（R8 压缩）
```

- 版本号：默认 `1.0.0`（versionCode 1）；可用 `-PhvVersionName=1.2.3 -PhvVersionCode=10203` 覆盖。
  CI 在推送标签 `v1.2.3` 时自动使用 versionName `1.2.3`、versionCode `10203`（主版本×10000 + 次版本×100 + 修订号）。
- 正式签名：设置环境变量 `HV_ANDROID_KEYSTORE_FILE`（keystore 路径）、`HV_ANDROID_KEYSTORE_PASSWORD`、
  `HV_ANDROID_KEY_ALIAS`、`HV_ANDROID_KEY_PASSWORD` 后再 `assembleRelease`；没设置时 release 版用本机的 debug 密钥签名。
- 构建工具版本：Android Gradle Plugin 9.3.2（内置 Kotlin 支持，无需单独的 Kotlin 插件）、Gradle 9.7.1（wrapper 带 SHA-256 校验）、
  compileSdk / targetSdk 36、minSdk 26。
- 中国大陆网络：`dl.google.com` 一般可以直接访问。如果依赖下载失败，可以在 `~/.gradle/init.d/mirrors.init.gradle.kts` 里加镜像，例如：

  ```kotlin
  settingsEvaluated {
      pluginManagement.repositories {
          maven("https://maven.aliyun.com/repository/google")
          maven("https://maven.aliyun.com/repository/gradle-plugin")
      }
      dependencyResolutionManagement.repositories {
          maven("https://maven.aliyun.com/repository/google")
          maven("https://maven.aliyun.com/repository/public")
      }
  }
  ```

### GitHub Actions（`.github/workflows/android.yml`）

- 修改 `android/**` 后推送、手动运行（workflow_dispatch）或推送 `v*` 标签时：构建 debug + release APK，运行 lint 和单元测试，
  上传构建产物 `homevault-android`（`homevault-android.apk`、`.sha256`、debug 版）。
- 推送标签 `v1.2.3` 时，还会把 `homevault-android.apk` 和 `.sha256` 附加到对应的 GitHub Release
  （`hv android fetch` 从 `HV_ANDROID_RELEASE_REPO` 仓库的最新 Release 下载：Windows 版固定下载
  `releases/latest/download/homevault-android.apk` 并用同目录的 `.sha256` 校验；Linux 版通过 GitHub API 取最新 Release 里的 APK）。
- **正式签名（强烈建议配置）**：在仓库 Settings → Secrets and variables → Actions 添加：

  | Secret | 内容 |
  |---|---|
  | `HV_ANDROID_KEYSTORE_B64` | keystore 文件的 base64 |
  | `HV_ANDROID_KEYSTORE_PASSWORD` | keystore 密码 |
  | `HV_ANDROID_KEY_ALIAS` | 密钥别名 |
  | `HV_ANDROID_KEY_PASSWORD` | 密钥密码 |

  生成密钥（只做一次，并把 `.jks` 和密码**离线备份**；丢失后发布的新版本无法覆盖安装旧版本）：

  ```bash
  keytool -genkeypair -v -keystore homevault-release.jks -alias homevault \
          -keyalg RSA -keysize 4096 -validity 10000
  base64 -w0 homevault-release.jks      # 把输出填到 HV_ANDROID_KEYSTORE_B64
  ```

  没有配置时，release 版用 CI 每次临时生成的 debug 密钥签名：可以安装使用，但每个版本的签名都不同，升级时必须先卸载旧版。
  `pull_request` 触发的构建（运行的是 PR 里的代码）不会拿到这些 Secrets，一律用临时 debug 密钥签名。

## 目录结构

```
android/
├── settings.gradle.kts / build.gradle.kts / gradle.properties
├── gradlew, gradlew.bat, gradle/wrapper/         Gradle 9.7.1 wrapper
└── app/
    ├── build.gradle.kts                           applicationId app.homevault.android
    ├── proguard-rules.pro, lint.xml
    └── src/
        ├── main/AndroidManifest.xml
        ├── main/java/app/homevault/android/
        │   ├── MainActivity.kt        WebView、菜单、下载、证书错误处理、返回键
        │   ├── SetupActivity.kt       首次设置 / 更换服务器 / 测试连接
        │   ├── ConnectionTester.kt    “测试连接”的 HTTPS 诊断（/api/info、/status.php）
        │   ├── PanelInfo.kt           解析面板 /api/info 与 Nextcloud status.php（纯 JVM，有单元测试）
        │   ├── HomeVaultActions.kt    打开 Nextcloud / VPN、证书说明、关于
        │   ├── UrlRules.kt            地址校验与同源判断（纯 JVM，有单元测试）
        │   ├── ServerConfig.kt        保存服务器地址
        │   └── SystemBars.kt          Android 15+ 全面屏边距
        ├── main/res/                  中文字符串、布局、矢量图标、network_security_config
        └── test/                      UrlRules / PanelInfo 单元测试（JUnit 4）
```

## 常见问题

- **打开后显示“连接不上”**：在家确认连的是家里的 Wi-Fi；在外面先打开 VPN 再点“重试”。
- **提示“证书不受信任”**：按上文安装根证书；如果提示“地址不匹配”，请改用服务器安装完成时显示的地址。
- **更新时提示“签名不一致 / 与已安装的应用冲突”**：旧版本是用临时密钥签名的（仓库没配置签名 Secrets），先卸载旧版再安装。
- **“文件”按钮打开的是浏览器**：说明没装 Nextcloud 应用；按提示下载安装后再点。
- **Nextcloud 不在 443 端口**：在“更换服务器”里填写“Nextcloud 网页地址（可选）”。
