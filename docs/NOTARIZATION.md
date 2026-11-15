# macOS 签名、Hardened Runtime、Entitlement 与公证

本文档记录 VideoFlow 0.1.0 的签名链路现状、`com.apple.security.cs.disable-library-validation`
这个 entitlement 为什么保留、它的安全影响，以及公证（notarization）的实现与当前启用状态。

> 结论先行：**本项目当前不使用 Apple Developer Program，公证能力已实现但未启用**。
> 推送 `v*` tag 产出的是明确声明的 **unsigned / notarization-free 测试发行版**（GitHub Pre-release），
> 不再因为“缺凭据”被判 BLOCKED。签名与公证的完整实现保留在代码里，重新申请账号后可直接启用。
> 其余签名项（Developer ID 签名链路、Hardened Runtime、entitlement）保持既有结论。

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

## 3. 公证：流程已落地，当前模式不启用

### 3.1 现状：三种发布模式，只有 signed 模式要求公证

公证流程实现在 `scripts/notarize.sh`，但 `REQUIRE_NOTARIZATION` 不再是常量：

| 模式 | 触发 | `REQUIRE_NOTARIZATION` | 公证 |
| --- | --- | --- | --- |
| internal | `workflow_dispatch` + `internal_build=true` | `false` | 不执行 |
| **test release** | 推送 `v*` tag | `false` | 不执行 |
| signed | `workflow_dispatch`（其它情况） | `true` | 执行，缺凭据即 `BLOCKED` |

当前仓库不配置任何 Apple 凭据，因此 tag 发布固定走 **test release**：unsigned、未公证，
状态写 `NOT_NOTARIZED`，产物以 **GitHub Pre-release** 分发（详见 7.2.2）。
signed 模式仍然存在且门禁未削弱，只是暂时没有入口会用到它。本文档不声称已经完成过公证。

### 3.2 凭据来源：只支持 App Store Connect **Team** API Key

本项目只接受 Team API Key，不使用 Apple ID + app-specific password：

| 变量 | 含义 |
| --- | --- |
| `APPLE_API_KEY` | Key ID（10 位以上字母数字） |
| `APPLE_API_ISSUER` | Issuer ID（UUID） |
| `APPLE_API_KEY_PATH` / `APPLE_API_KEY_P8_BASE64` | `.p8` 私钥路径，或私钥的 base64（CI 用后者） |

`notarytool` 的 `--issuer` 是 Team Key 的必填参数、Individual Key 不需要，脚本恒传 `--issuer`，
因此 Individual Key 在协议层就无法通过。

### 3.3 本地手工执行

```bash
export APPLE_API_KEY="<key-id>"
export APPLE_API_ISSUER="<issuer-uuid>"
export APPLE_API_KEY_PATH="$HOME/.appstoreconnect/private_keys/AuthKey_<key-id>.p8"
export REQUIRE_NOTARIZATION=true
pnpm tauri build --target aarch64-apple-darwin   # 注意：不要给 bundler 传 APPLE_API_* 变量
./scripts/notarize.sh                            # submit → 取 Apple 状态 → staple → validate
```

> Tauri bundler 在检测到 `APPLE_API_KEY` / `APPLE_API_ISSUER` / `APPLE_API_KEY_PATH` 时会自行公证，
> 那样 Apple 的返回会被吞在 bundler 内部。本项目刻意不这样做：公证只由 `notarize.sh` 执行，
> 以便把 submission ID、真实状态、失败日志全部落盘。

### 3.4 公证后的验收清单

| 命令 | 期望 |
| --- | --- |
| `codesign --verify --deep --strict --verbose=2 VideoFlow.app` | `valid on disk`、`satisfies its Designated Requirement` |
| `xcrun stapler validate VideoFlow.app` | `The validate action worked!` |
| `xcrun stapler validate VideoFlow_0.1.0_aarch64.dmg` | `The validate action worked!` |
| `spctl -a -vvv -t exec VideoFlow.app` | `accepted` / `source=Notarized Developer ID` |
| `spctl -a -vvv -t install VideoFlow_0.1.0_aarch64.dmg` | `accepted` |
| 干净机器（或新用户）双击打开 | 无“无法验证开发者”拦截 |

> 注意：公证产物与签名强绑定。任何一次重新构建、替换 sidecar（例如用户按 LGPL 要求替换 `ffmpeg`）
> 之后都必须重新签名，替换 ffmpeg 不会使 `yt-dlp` 的 entitlement 失效，但会让 app 签名失效，需要重签整个 app。

> 已知结构限制：DMG 由 Tauri 在公证之前生成，因此 DMG 内部的那份 `.app` 没有独立票据；
> 票据装在 `.dmg` 与 `bundle/macos` 下打包进 `.app.zip` 的那份 `.app` 上。
> 从 DMG 安装的应用依赖 DMG 自身票据 + Gatekeeper 在线核验（Apple 对仅公证 DMG 的标准行为）。

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
| 公证流水线 | 在 CI 中固定 API Key 公证 + staple + `spctl` 断言 | 实现已完成（Phase 4），启用前置是 Apple Developer Program 账号与三个公证 Secrets |
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
| 0/3 | `workflow_dispatch`（非 internal） | `unsigned`，但满足不了 `REQUIRE_NOTARIZATION=true`，最终 BLOCKED |
| 0/3 | `workflow_dispatch` + `internal_build=true` | `unsigned`，产物 `videoflow-internal-test-<ver>-<sha>`，只出 Artifact（Phase 5） |
| 0/3 | `v*` tag | `unsigned` + **test release**（Phase 6，见 7.2.2），创建 Pre-release |
| 3/3 | `workflow_dispatch`（非 internal） | `developer-id`，随后进入公证 |
| 3/3 | `v*` tag | **仍强制 unsigned**：tag 不再走真实签名，避免产出“签了名但没公证”的灰色制品 |
| 1~2/3 | 任意 | **立即失败**（避免“以为签了其实没签”） |

因此当前（无 Apple 账号）的实际入口有两个：`workflow_dispatch + internal_build=true` 拿内部 Artifact，
`v*` tag 拿测试发行 Pre-release。真实签名路径保留给未来配置齐 3 个签名 Secrets 后的
`workflow_dispatch`（非 internal）。

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

---

## 7. CI 公证接入（Phase 4）

### 7.1 需要配置的 Secrets（App Store Connect **Team** API Key）

| Secret | 内容 | 取得方式 |
| --- | --- | --- |
| `APPLE_API_KEY` | Key ID | App Store Connect → 用户和访问 → 集成 → App Store Connect API → 生成密钥（访问权限选 **App Manager** 或更高） |
| `APPLE_API_ISSUER` | Issuer ID（UUID） | 同页顶部的 Issuer ID |
| `APPLE_API_KEY_P8_BASE64` | `.p8` 文件内容的 base64 | `base64 -i AuthKey_XXXXXXXXXX.p8 \| tr -d '\n' \| pbcopy` |

要点：

- 必须是 **Team Key**。Individual Key 没有 Issuer，而脚本恒传 `--issuer`，会直接被 Apple 拒绝。
- `.p8` 只能下载一次，丢失只能重新生成（旧 Key 需吊销）。
- base64 只是编码，不是加密：不要把它写进任何文件、文档或 Issue。

### 7.2 行为矩阵

| 签名 Secrets | 公证 Secrets | 触发 | 结果 |
| --- | --- | --- | --- |
| 3/3 | 3/3 | `workflow_dispatch`（非 internal，`dry_run=false`） | 正常签名 → 公证 → 创建 Release |
| 3/3 | 0/3 | `workflow_dispatch`（非 internal） | `BLOCKED`，构建失败，不发布 |
| 任意 | 任意 | `workflow_dispatch` + `internal_build=true` | unsigned Artifact，跳过公证，永不创建 Release |
| 任意 | 任意 | 推送 `v*` tag | **test release**：强制 unsigned、跳过公证、创建 Pre-release（不看任何 Apple 凭据） |
| 任意 | 1~2/3 | `workflow_dispatch`（非 internal） | 立即失败（不允许半配置） |

### 7.2.1 内部测试构建（`internal_build`，Phase 5）

唯一能在无凭据时拿到安装包的入口，也是唯一能把 `REQUIRE_NOTARIZATION` 降为 `false` 的入口：

| 条件 | 结果 |
| --- | --- |
| `workflow_dispatch` + `internal_build=true` | 强制 `unsigned` → `ALLOW_UNSIGNED=1` → 跳过公证 → 产物名 `videoflow-internal-test-<version>-<sha>` |
| `internal_build=true` + tag 触发 | 不可能：该输入只定义在 `workflow_dispatch`，且 validate 会读 `GITHUB_REF_TYPE` 再拦一次 |
| `internal_build=true` 且配了签名 Secrets | 仍强制 unsigned（签名包改写 DMG 会破坏签名，且会制造“签了名但没公证”的灰色制品） |
| `internal_build=true` | release job 的 `if` 含 `inputs.internal_build != true`，永远不会创建 Release；build job 只有 `contents: read` |

内部测试包的 `INTERNAL TEST BUILD - NOT NOTARIZED` 会同时出现在：文件名、DMG 卷内的 `INTERNAL_TEST_BUILD.txt`、`dist-release/INTERNAL_TEST_BUILD.txt`、`release-manifest.json` 的 `build_kind` / `distribution_notice`、`verification-report.txt` 首行、Step Summary。

### 7.2.2 Tag 测试发行（`test_release`，Phase 6）

在**没有 Apple Developer Program 账号**的前提下的默认发布方式。它不是“绕过检查”，
而是把发布类型明确声明为未签名、未公证的测试发行版：

| 条件 | 结果 |
| --- | --- |
| 推送 `v*` tag | `TEST_RELEASE=true`、`INTERNAL_BUILD=false`、`REQUIRE_NOTARIZATION=false`、`SIGNING_MODE=unsigned`、`ALLOW_UNSIGNED=1` |
| Apple Secrets 是否存在 | **完全不检查**：`signing` / `notarize_creds` 两个判定步骤在 test 分支直接返回，不会因为“没有凭据”失败 |
| Apple 公证步骤 | `if: env.INTERNAL_BUILD != 'true' && env.TEST_RELEASE != 'true'` → 跳过 |
| 产物名 | `VideoFlow_0.1.0_aarch64.dmg` / `.app.zip`（与正式版同形，不带 unsigned 标记）；Artifact 名 `videoflow-test-release-<ver>-<sha>` |
| 包内标记 | DMG 卷内 `TEST_RELEASE.txt`（写不进去直接中止发布） |
| manifest | `build_kind: test-release`、`signing.mode: unsigned`、`signing.identity: null`、`notarization.status: NOT_NOTARIZED`、`ticket_stapled.dmg/app: false`、`distribution_notice: TEST RELEASE - UNSIGNED - NOT NOTARIZED` |
| GitHub Release | `prerelease: true`，标题 `VideoFlow v0.1.0 - Test Release`；已存在同名 Release 时拒绝覆盖 |

防止伪造的三道断言（缺一不可）：

1. `verify-release.sh` 在 `TEST_RELEASE=true` 时只接受 `NOT_NOTARIZED`，碰到 `ACCEPTED` 直接 `fail`；
2. 同一模式下断言 `.dmg` / `.app` **不带**公证票据（`stapler validate` 必须失败），
   与 Phase 4 “必须带票据”的断言互为镜像；
3. `release` job 下载产物后重新核对 manifest 五元组（`build_kind` / `signing.mode` /
   `notarization.status` / `ticket_stapled.*` / `distribution_notice`）才创建 Release。

行为矩阵的“强制 unsigned”不是自述：`package-release.sh` 会拒绝 `SIGNING_MODE=developer-id`
和 `dmg_signed=true`，也就是说测试发行包不可能是签名产物。

### 7.3 流水线顺序（`release.yml` 的 build job）

```
导入 Developer ID 证书 → 构建（bundler 不公证）→ 清理 keychain
  → notarize.sh（submit → 真实 status → 仅 Accepted 才 staple → validate）
  → 清理临时私钥 → verify-release.sh（含票据硬断言）
  → package-release.sh（staple 之后才生成 SHA256SUMS）
  → 上传产物
  → release job（tag 且全部通过）：SHA256SUMS 复核 → 清单复核 → 票据复验 → 拒绝覆盖 → gh release create
```

关键点：**SHA256SUMS 必须覆盖带票据的最终制品**，所以打包发生在 staple 之后。

### 7.4 私钥生命周期

| 阶段 | 位置 | 约束 |
| --- | --- | --- |
| 传入 | `secrets.APPLE_API_KEY_P8_BASE64` | 仅注入到公证步骤的 `env` |
| 落盘 | `$RUNNER_TEMP/AuthKey_<KEYID>.p8` | `umask 077` + `chmod 600` |
| 使用 | `notarytool submit/log` 的 `--key` 参数 | 只传路径，不传内容，不进日志 |
| 清理 | `trap` + 独立 `always()` 步骤 | 先 `dd` 覆写再 `rm`，并断言无残留 |

私钥**不会**进入：仓库、`dist-release`、Artifact、Release 资产、Step Summary、日志。
认证只传路径与 Key ID，`APPLE_API_*` 不会出现在命令行参数里。

### 7.5 新增硬门禁

`verify-release.sh`（`REQUIRE_NOTARIZATION=true` 时）：

| 断言 | 防的是什么 |
| --- | --- |
| `stapler validate`（`.dmg`） | 用户下载的 DMG 真有票据 |
| `stapler validate`（`.app`） | 打进 `.app.zip` 的包真有票据 |
| `NOTARIZATION_STATUS == ACCEPTED` | 状态必须来自 Apple 返回 |
| `spctl` 返回 `accepted` | Gatekeeper 实际放行 |

`package-release.sh`：`stapler validate` 复验**复制后**的 DMG，无票据且 `REQUIRE_NOTARIZATION=true` 时直接失败；
manifest 的 `ticket_stapled` 由实测得出，不信环境变量。

`release` job：`shasum -c SHA256SUMS`、manifest 的 version/tag/公证状态/票据、再跑一次 `stapler validate`、
并拒绝覆盖已存在的同名 Release。

### 7.6 当前验证状态

| 环节 | 状态 | 证据 |
| --- | --- | --- |
| 无凭据 → `BLOCKED`（exit 1，报告/GITHUB_ENV/Summary 三处一致） | **PASS** | 本地实跑 |
| `REQUIRE_NOTARIZATION=false` → `NOT_NOTARIZED`（不阻断） | **PASS** | 本地实跑 |
| 半配置凭据 / Issuer 非 UUID / Key ID 格式错 / `.p8` 非法 | **PASS** | 4 类负例均 `FAILED` 且落盘 |
| 真实调用 Apple（伪造凭据） | **PASS** | Apple 返回 `HTTP 401 Unauthenticated`，脚本记为 `FAILED`，未伪造成功 |
| 私钥不泄漏 | **PASS** | 报告与日志均不含 base64；进程退出后文件已删除 |
| 公证门禁（无票据时 3 项 FAIL） | **PASS** | 真实已签名 DMG：42 项中 3 项失败，均属公证项 |
| 门禁无法用标签绕过 | **PASS** | 伪造 `NOTARIZATION_STATUS=ACCEPTED` 仍被票据断言拦住 |
| `package-release.sh` 无票据拒绝打包 | **PASS** | 报“复制后的 DMG 丢失公证票据，不得发布” |
| tag 测试发行门禁（14 个场景） | **PASS** | `scripts/test-release-gating.sh`，76 项断言全通过 |
| 测试发行全链路（tag → Pre-release → DMG 安装启动） | **PASS** | `v0.1.0-test.3`（run 43692793949）：Pre-release 创建成功、6 资产、`shasum -c` 全 OK、DMG 挂载/安装/启动正常。详见 `docs/CI_CD_REPORT.md` |
| 无 Apple 凭据时 tag 发布不再 `BLOCKED` | **PASS** | 三次 tag 实跑均通过 `validate` 的凭据检查（该路径已跳过） |
| 产物确实未签名且无票据 | **PASS** | `codesign -dv` 无 `Authority=Developer ID`（仅 adhoc/linker-signed）、`stapler validate` 报无票据、manifest `ticket_stapled` 全 false |
| workflow 全部 `run` 块语法 | **PASS** | 46 个 run 块 `bash -n` 全通过 |
| **真实凭据下的完整公证（Accepted → staple → 发布）** | **NOT TESTED** | 仓库无凭据；尚未真实跑过（本轮不申请 Apple Developer Program） |
| **`stapler staple` 对 DMG 内 `.app` 副本的行为** | **NOT TESTED** | 见 3.4 的结构限制说明 |
| **signed 模式真实创建正式 Release** | **NOT TESTED** | 需配齐 6 个 Apple Secrets 后手动 dispatch |
