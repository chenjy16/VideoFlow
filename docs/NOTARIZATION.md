# macOS 签名、Hardened Runtime、Entitlement 与公证

本文档记录 VideoFlow 0.1.0 的签名链路现状、`com.apple.security.cs.disable-library-validation`
这个 entitlement 为什么保留、它的安全影响，以及公证（notarization）当前为何处于 BLOCKED。

> 结论先行：**公证未完成（BLOCKED，缺凭据）**。其余签名项通过。本轮按决策保留 yt-dlp 的
> onefile 打包与现有 entitlement，**不为移除 entitlement 改动已验证的下载核心**。

---

## 1. 签名链路现状

| 项 | 状态 / 证据 |
| --- | --- |
| 证书 | `Developer ID Application: jianyu chen (HQC33J8U5Y)` |
| 签名命令 | `APPLE_SIGNING_IDENTITY="Developer ID Application: jianyu chen (HQC33J8U5Y)" pnpm tauri build --target aarch64-apple-darwin` |
| 被签名对象 | `videoflow`（主程序）、`yt-dlp`、`ffmpeg`、`ffprobe`（全部位于 `Contents/MacOS/`），最后是整个 `.app` |
| Hardened Runtime | 启用，`codesign -dv` 显示 `flags=0x10000(runtime)` |
| Timestamp | 已带（Tauri 默认 `--timestamp`） |
| `codesign --verify --deep --strict` | 通过：`valid on disk` / `satisfies its Designated Requirement` |
| Entitlement | 4 个可执行文件都带 `com.apple.security.cs.disable-library-validation` |
| 公证 | **未做**，Tauri 输出 `Warn skipping app notarization, no APPLE_ID & APPLE_PASSWORD & APPLE_TEAM_ID or APPLE_API_KEY ...` |
| 票据装订 | `xcrun stapler validate` → `does not have a ticket stapled to it` |
| Gatekeeper | `spctl -a -vvv -t install` → `rejected` / `source=Unnotarized Developer ID`（未公证的预期结果） |

关于 entitlement 的扩散：Tauri 用 `--deep` 方式对 `.app` 整体签名，导致 `bundle.macOS.entitlements`
指定的权限被**应用到所有嵌套二进制**（包括 ffmpeg / ffprobe / yt-dlp）。当前构建结果就是这种形态。

---

## 2. 为什么保留 `disable-library-validation`

### 2.1 触发原因（不是“省事”，是功能性必需）

yt-dlp 以 **PyInstaller onefile** 分发。运行时 bootloader 会把内嵌的 `Python.framework`（CPython 3.14）
解压到临时目录，再用 `dlopen` 加载其中的 `.so`。该 framework 携带的是**上游 PyInstaller/Python 的签名**，
Team ID 与 VideoFlow 不同；开启 Hardened Runtime 后，library validation 会拒绝加载非同一 Team ID 的
动态库，结果：

- sidecar 直接 `exit=255`；
- 设置页版本号显示 `(unknown)`；
- 所有下载失败。

在不改打包架构的前提下，唯一可行的手段就是关闭 library validation。

### 2.2 本轮决策

| 决策 | 内容 |
| --- | --- |
| 保留 onefile | 不重建 Python onedir，不改 yt-dlp 打包架构 |
| 保留 entitlement | `com.apple.security.cs.disable-library-validation` 继续随包 |
| 不破坏功能 | 任何“为了去掉 entitlement”的改动都不在本轮范围 |
| 未来项目 | onedir 与 entitlement 收敛作为**独立技术评估项目**，见第 5 节 |

### 2.3 安全影响（必须如实告知）

| 影响 | 说明 |
| --- | --- |
| 削弱 Hardened Runtime 的库加载校验 | 进程内代码可以 `dlopen` 任意来源的 `.dylib`，不再要求签名一致。这是该 entitlement 的定义行为。 |
| 影响范围偏大 | 因为 `--deep` 扩散，**主进程 `videoflow` 也带上了该权限**，不只是 yt-dlp。理论上主进程一旦被注入，加载恶意 dylib 的门槛更低。 |
| 未削弱的部分 | Hardened Runtime 的其它保护仍然生效（如：不允许未签名的可执行页、Dyld 环境变量清理等）；应用仍为 Developer ID 签名 + （待完成）公证，篡改会破坏签名与票据。 |
| 实际攻击面 | 需要攻击者已能在应用进程内执行代码，或已能在 `Contents/MacOS` 或临时目录写入 dylib 并诱导加载。攻击者具备该能力时通常已可造成更大破坏。 |
| 缓解措施 | ① 完成公证并装订票据，使 Gatekeeper 更严格；② 后续按第 5 节把 entitlement 收敛到**仅 yt-dlp**；③ 不在应用内加载任何用户可控路径的 dylib。 |

### 2.4 已验证的收敛空间（本轮未启用）

在 `/tmp/vf-ent-test` 的应用副本上做过实验：

1. 对 `ffmpeg` / `ffprobe` **不带 entitlements** 重新签名，再重签整个 `.app`；
2. `codesign --verify --deep --strict` 通过；
3. 两个工具正常运行，且用随包 yt-dlp 完成一次 MP3 提取成功。

说明 ffmpeg / ffprobe **不需要**该 entitlement，entitlement 只需覆盖 `yt-dlp`（以及被 `--deep` 波及的主程序）。
但收敛需要自定义签名顺序（先逐个签嵌套二进制，再签 app 且不带 `--deep` 扩散），属于工具链改造，
本轮按决策**不做**，列入第 5 节。

---

## 3. 公证：当前 BLOCKED

### 3.1 阻塞原因

构建环境没有以下任意一组凭据：

- Apple ID 路线：`APPLE_ID`、`APPLE_PASSWORD`（app-specific password）、`APPLE_TEAM_ID`；
- API Key 路线：`APPLE_API_KEY`、`APPLE_API_ISSUER`、`APPLE_API_KEY_PATH`。

`notarytool` 也没有可用的 keychain profile。因此**没有执行** `notarytool submit`，也**没有**装订票据。
本文档不声称已完成公证。

### 3.2 凭据就绪后的操作（模板）

路线 A：Apple ID + app-specific password

```bash
export APPLE_ID="<apple-id>"
export APPLE_PASSWORD="<app-specific-password>"
export APPLE_TEAM_ID="HQC33J8U5Y"
pnpm tauri build --target aarch64-apple-darwin     # Tauri 会自动 submit + staple
```

路线 B：App Store Connect API Key（CI 推荐）

```bash
export APPLE_API_KEY="<key-id>"
export APPLE_API_ISSUER="<issuer-uuid>"
export APPLE_API_KEY_PATH="$HOME/.appstoreconnect/private_keys/AuthKey_<key-id>.p8"
pnpm tauri build --target aarch64-apple-darwin
```

手工补做（若构建时未自动公证）：

```bash
xcrun notarytool submit "src-tauri/target/aarch64-apple-darwin/release/bundle/dmg/VideoFlow_0.1.0_aarch64.dmg" \
  --apple-id "$APPLE_ID" --password "$APPLE_PASSWORD" --team-id "$APPLE_TEAM_ID" --wait
xcrun stapler staple "src-tauri/target/aarch64-apple-darwin/release/bundle/macos/VideoFlow.app"
xcrun stapler staple "src-tauri/target/aarch64-apple-darwin/release/bundle/dmg/VideoFlow_0.1.0_aarch64.dmg"
```

### 3.3 公证后的验收清单

| 命令 | 期望 |
| --- | --- |
| `codesign --verify --deep --strict --verbose=2 VideoFlow.app` | `valid on disk`、`satisfies its Designated Requirement` |
| `xcrun stapler validate VideoFlow.app` | `The validate action worked!` |
| `spctl -a -vvv -t exec VideoFlow.app` | `accepted` / `source=Notarized Developer ID` |
| `spctl -a -vvv -t install VideoFlow_0.1.0_aarch64.dmg` | `accepted` |
| 干净机器（或新用户）双击打开 | 无“无法验证开发者”拦截 |

> 注意：公证产物与签名强绑定。任何一次重新构建、替换 sidecar（例如用户按 LGPL 要求替换 `ffmpeg`）
> 之后都必须重新签名，替换 ffmpeg 不会使 `yt-dlp` 的 entitlement 失效，但会让 app 签名失效，需要重签整个 app。

---

## 4. 常见误判澄清

| 误解 | 事实 |
| --- | --- |
| “不加 entitlement 也能跑，所以是多余的” | 只在开发机（无 Hardened Runtime 或已缓存授权）成立；签名后的 onefile 会在干净环境 `exit 255`。本轮已用签名产物复现该失败链路。 |
| “`--deep` 签名 = 每个二进制都正确签名” | `--deep` 会签嵌套代码，但也会把 app 级 entitlement 扩散到所有嵌套二进制，不利于最小权限。 |
| “没公证但签名了就等于可分发给用户” | 不成立。未公证的 Developer ID 应用在 Gatekeeper 下仍是 `rejected`，用户需右键打开或手动去隔离属性。 |
| “移除 entitlement 只要改 plist” | 对本项目等价于“换掉 onefile 打包方式或改变 Python.framework 加载方式”，属架构改动。 |

---

## 5. 未来独立技术评估项目

| 项目 | 目标 | 说明 |
| --- | --- | --- |
| yt-dlp 改为 PyInstaller **onedir** | 让 `Python.framework` 与 `.so` 落在稳定路径、由我们统一签名，从而可能去掉 entitlement | 在**当前 PyInstaller 架构下**，onedir 是更值得评估的方案（同 Team ID、无需运行时解压、可整体签名）。但**不是唯一方案**；其它候选包括：为 framework 重新签名、改用 `--onedir` + `--contents-directory`、或改为调用系统 Python（需评估依赖与体积）。 |
| entitlement 收敛到最小范围 | 仅让 `yt-dlp` 携带 `disable-library-validation`，主程序与 ffmpeg/ffprobe 保持无权限 | 已实验验证 ffmpeg/ffprobe 可去掉（2.4 节）；需要自定义签名顺序，绕开 `--deep` 扩散 |
| 公证流水线 | 在 CI 中固定 API Key 公证 + staple + `spctl` 断言 | 本轮 BLOCKED 的根因是凭据缺失 |
| Intel / universal | 覆盖 x86_64 用户 | 需重建 FFmpeg 并重新取证 |

以上均为独立评估项，进入前需各自明确验收标准，不得以“去掉 entitlement”本身为目标破坏现有功能。

---

## 6. CI 签名接入（Phase 3）

CI 的签名模式完全由 Secrets 推导，**不做隐式降级**。

### 6.1 需要配置的三个 Secrets

| Secret | 内容 | 说明 |
| --- | --- | --- |
| `APPLE_CERTIFICATE` | `.p12` 的 base64（单行） | `openssl base64 -A -in cert.p12 -out cert-base64.txt` |
| `APPLE_CERTIFICATE_PASSWORD` | 导出 `.p12` 时设置的密码 | |
| `APPLE_SIGNING_IDENTITY` | 证书全名 | `security find-identity -v -p codesigning` 引号内的文字，例如 `Developer ID Application: jianyu chen (HQC33J8U5Y)` |

导出要求：

1. Keychain Access →「我的证书」→ 展开证书 → 右键私钥 → 导出，格式选 `.p12`；
2. **不要**用 OpenSSL 3+ 直接 `openssl pkcs12 -export` 生成：其默认 AES-256/SHA-256 加密，macOS 的
   `SecKeychainItemImport` 读不了（报 `MAC verification failed`）。必须用 Keychain Access 导出，
   或显式加 `-legacy`。导入脚本会把这个错误识别成明确的提示，而不是让它变成难查的签名失败。

### 6.2 行为矩阵（`release.yml`）

| Secrets | 触发方式 | 结果 |
| --- | --- | --- |
| 0/3 | `workflow_dispatch` | `unsigned`，产物 `videoflow-internal-unsigned-<ver>`，仅供内部测试 |
| 3/3 | 任意 | `developer-id`，产物 `videoflow-signed-unnotarized-<ver>` |
| 1~2/3 | 任意 | **立即失败**（避免“以为签了其实没签”） |
| 0/3 | `v*` tag | **立即失败**（正式 Release 不接受未签名产物） |

因此没有 Secrets 的环境只能用 `workflow_dispatch` 做内部构建；`v*` tag 一旦推送就要求签名齐备。

### 6.3 私钥在流水线中的生命周期

1. `scripts/import-signing-certificate.sh` 新建临时 keychain，密码随机生成，只写到 `$RUNNER_TEMP`
   下 0600 文件，**不进 `GITHUB_ENV`**（避免日志回显）；
2. 导入 `.p12` → `set-key-partition-list`，让 `codesign` 无需人工确认即可使用私钥；
3. 把 keychain 加入用户搜索列表（原有条目全部保留）；
4. 回填 `APPLE_SIGNING_IDENTITY` / `VIDEOFLOW_TEAM_ID` 供后续断言；
5. `pnpm tauri build` 期间只靠 `APPLE_SIGNING_IDENTITY` 触发签名，**不向 bundler 传 `APPLE_CERTIFICATE`**，
   避免 Tauri 重复导入证书；
6. 构建结束立即执行 `--cleanup` 删除 keychain、擦除密码文件、复原搜索列表（`if: always()`）。

### 6.4 发布校验新增断言

`scripts/verify-release.sh` 在 `SIGNING_MODE=developer-id` 下额外校验：

| 断言 | 目的 |
| --- | --- |
| `codesign --verify --deep --strict`（.app） | 主程序与全部 sidecar 签名有效 |
| `codesign --verify --strict`（.dmg）+ Authority | 用户双击的 DMG 本身已签名 |
| `Authority=Developer ID Application` | 证书类型正确 |
| `Authority=Developer ID Certification Authority` | 证书链来自 Apple，防自签名同名证书冒充 |
| `Authority=<APPLE_SIGNING_IDENTITY>` 精确匹配 | 用的就是预期身份 |
| `flags=0x10000` | Hardened Runtime 生效 |
| `Timestamp=` | 有安全时间戳（公证的前置条件） |
| `.app` / `.dmg` Team ID 一致，且等于证书的 Team | 签名归属一致 |
| 主程序与 yt-dlp 均含 `disable-library-validation` | 防 onefile 运行失败（见第 2 节） |

`spctl` 在未公证时必然是 `rejected source=Unnotarized Developer ID`，脚本**只记录**并说明这是预期，
不判失败；完成公证后应变为 `accepted`。

### 6.5 当前验证状态

| 环节 | 状态 | 证据 |
| --- | --- | --- |
| 导入脚本负例（缺 Secrets / 密码错 / 非 p12 / macOS 不支持的 AES p12） | **PASS** | 本地逐项跑通，均给出明确报错 |
| 导入脚本正例（创建 keychain、导入、私钥可用、搜索列表、清理） | **PASS** | 自签名证书本地测试；`codesign` 实测能用导入的私钥签出文件 |
| 信任链有效性门禁（负例） | **PASS** | 自签名证书被判 `CSSMERR_TP_NOT_TRUSTED` 并拒绝 |
| Team ID 提取与 `GITHUB_ENV` 回填 | **PASS** | 本地测试：`VIDEOFLOW_TEAM_ID` 正确 |
| 签名模式判定矩阵（7 种 Secrets 组合） | **PASS** | 从 `release.yml` 抽出判定块穷举 |
| `verify-release.sh` developer-id 分支 | **PASS（39 项）** | 用本地真实 Developer ID 签名的 DMG 实跑 |
| `package-release.sh` 签名字段取自产物 | **PASS** | manifest 输出 identity / team_id / dmg_signed |
| **CI 上使用真实 Developer ID 证书从零签名** | **NOT TESTED** | 需先配置三个 Secrets；本轮未配置，故未跑过 |

