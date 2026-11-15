# 发布手册（Release）

本文档描述 VideoFlow 的三种发布模式、每一步的硬门禁，以及用户拿到 DMG 后如何验证。
签名与公证的技术细节见 [NOTARIZATION.md](./NOTARIZATION.md)，CI 结构见 [CI_CD.md](./CI_CD.md)，
实测记录（run ID / SHA256 / 安装验证）见 [CI_CD_REPORT.md](./CI_CD_REPORT.md)。

## 0. 一分钟速查

| 目标 | 触发方式 | 产物 | Release？ |
| --- | --- | --- | --- |
| 只想拿到一个能装的包自己试 | Actions → release → Run workflow，勾 `internal_build` | Actions Artifact `videoflow-internal-test-<ver>-<sha>` | 不创建 |
| 对外发一个测试版 | `git tag v0.1.0 && git push origin v0.1.0` | GitHub **Pre-release** + `VideoFlow_0.1.0_aarch64_TEST-UNSIGNED.dmg` | 创建（prerelease） |
| 未来发正式版 | 配齐 6 个 Apple Secrets 后 `workflow_dispatch`（不勾 internal，`dry_run=false`） | 正式 Release | 创建 |

三种模式互斥，由**触发方式**唯一决定，不做隐式降级：

```
tag                          → TEST_RELEASE=true   （强制 unsigned，不公证）
dispatch + internal_build    → INTERNAL_BUILD=true  （强制 unsigned，不公证）
dispatch 其它情况            → signed 路径（需要 Apple 凭据，缺则 BLOCKED）
```

## 1. Tag 测试发行（当前默认发布方式）

### 1.1 前置条件

- 三处版本号一致：`package.json`、`src-tauri/tauri.conf.json`、`src-tauri/Cargo.toml`。
- tag 名形如 `v0.1.0`，去掉前缀后必须与版本号完全相同。
- **不需要任何 Apple 凭据**：tag 路径不读取、不检查、不统计 Apple Secrets。

### 1.2 操作

```bash
# 1) 确认版本号三处一致
node -p "require('./package.json').version"

# 2) 打 tag 并推送（用 -test.N 后缀可以避免占用正式版本号）
git tag v0.1.0-test.1
git push origin v0.1.0-test.1
# 3) 观察流水线
gh run watch
```

### 1.3 流水线做了什么

1. **validate**：校验 runner 架构（arm64）、三处版本号、tag 与版本号一致；
   判定 `SIGNING_MODE=unsigned`、`TEST_RELEASE=true`、`REQUIRE_NOTARIZATION=false`，
   并**跳过**签名 / 公证凭据检查。
2. **ffmpeg**：复用 `ffmpeg-lgpl.yml` 构建 LGPL 版 ffmpeg/ffprobe，产出许可证与再链接材料。
3. **build**（只读权限）：安装依赖 → 校验 Rust 版本 → 取回 LGPL 产物 → 获取并校验 yt-dlp
   → `pnpm tauri build`（不签名）→ **跳过公证步骤** → `verify-release.sh` → `package-release.sh`
   → 上传 Artifact `videoflow-test-release-<ver>-<sha>`。
4. **release**（唯一持有 `contents: write`）：下载候选产物 → `shasum -c SHA256SUMS`
   → 复核 manifest → 断言**没有**公证票据 → 拒绝覆盖已有 Release → `gh release create --prerelease`。

### 1.4 产物清单（Release Assets）

| 文件 | 说明 |
| --- | --- |
| `VideoFlow_<ver>_aarch64_TEST-UNSIGNED.dmg` | 用户下载的安装镜像，卷内含 `TEST_RELEASE.txt` |
| `VideoFlow_<ver>_aarch64_TEST-UNSIGNED.app.zip` | `.app` 压缩包（ditto 打包，保留符号链接） |
| `SHA256SUMS` | 覆盖上面两个文件与下面三个材料文件 |
| `release-manifest.json` | 构建类型、签名、公证状态、引擎版本、许可证索引 |
| `THIRD_PARTY_LICENSES.md` | 第三方许可证汇总（对应需求里的 THIRD_PARTY_NOTICES） |
| `SOURCE_OFFER.txt` | FFmpeg LGPL 源码与再链接要约 |

共 **6 个** Release 资产。`verification-report.txt` 不进 Release，只随 Actions Artifact 保留；
`TEST_RELEASE.txt` 只存在于 DMG 卷内（写入后从发布目录删除，避免 SHA256SUMS 指向用户拿不到的文件）。

### 1.5 发布状态一致性（四处必须一致）

| 位置 | 内容 |
| --- | --- |
| DMG 卷内 `TEST_RELEASE.txt` | 首行 `TEST RELEASE - UNSIGNED - NOT NOTARIZED` |
| `release-manifest.json` | `build_kind: test-release`、`notarization.status: NOT_NOTARIZED`、`distribution_notice` |
| `verification-report.txt` | 首行 `TEST RELEASE - UNSIGNED - NOT NOTARIZED` |
| GitHub Release Notes + 标题 | `VideoFlow v0.1.0 - Test Release` + Gatekeeper 提示 |

任何一处不一致，`release` job 都会在创建 Release 之前失败。

### 1.6 用户安装说明（Release Notes 里已写入）

1. macOS 可能提示「无法验证开发者」或直接把应用移到废纸篓 —— 这是**未签名未公证**的预期行为；
2. 确认来源可信后：系统设置 → 隐私与安全性 → 仍要打开；
3. 或终端执行 `xattr -dr com.apple.quarantine /Applications/VideoFlow.app`；
4. `shasum -a 256 -c SHA256SUMS` 确认下载完整。

**不得宣称**该包已通过 Apple 公证或 Gatekeeper 完整验收。

### 1.7 校验和时序

`package-release.sh` 会把 `TEST_RELEASE.txt` 写进 DMG 卷内（UDRW → 拷文件 → UDZO），
这会改变文件字节，因此：

```
重建 DMG → dmg_sha 计算 → release-manifest.json → generate-checksums.sh（SHA256SUMS）
```

校验和永远针对**最终**的 DMG，不是写入标记之前的中间文件。

## 2. 内部构建（Internal Build）

用途：CI 上验证构建链路、自己安装试用，**绝不对外分发**。

```bash
gh workflow run release.yml -f dry_run=true -f internal_build=true
```

| 项目 | 值 |
| --- | --- |
| 签名 | 强制 `unsigned`（即使配了证书也不用） |
| 公证 | 不执行 |
| Artifact 名 | `videoflow-internal-test-<ver>-<sha>` |
| DMG 内标记 | `INTERNAL_TEST_BUILD.txt` |
| Release | **永不创建**（`release` job 的 `if` 含 `inputs.internal_build != true`） |

## 3. 未来正式签名发行（当前不可用）

前置条件：Apple Developer Program 账号 + 3 个签名 Secrets + 3 个公证 Secrets。

| 项目 | 值 |
| --- | --- |
| 触发 | `workflow_dispatch`，不勾 `internal_build`，`dry_run=false` |
| 签名 | Developer ID Application + Hardened Runtime + 时间戳 |
| 公证 | `notarize.sh` submit → 仅 Apple 返回 `Accepted` 才 staple |
| 门禁 | `verify-release.sh` 断言票据、`ACCEPTED`、`spctl accepted` |
| Release | 正式版（非 prerelease） |

代码路径完整保留，本轮没有任何删除。详见 NOTARIZATION.md 第 6、7 节。

## 4. 版本号与 tag 规则

- 三处版本号必须一致，不一致直接失败（`validate` 就地拦截）。
- tag 允许两种形态，其余一律失败：
  - 正式 tag：`v<version>`，例如 `v0.1.0`；
  - 测试 tag：`v<version>-test.<N>`，例如 `v0.1.0-test.1`（用于验证流水线而不占用正式版本号）。
- 注意：`v0.1.0-test.1` 不会因为版本号是 `0.1.0` 而被拦；但 `v0.1.1`、`v0.1.0-beta` 会失败。
- 同名 tag / Release 不会被覆盖：`gh release view` 命中即失败，`gh release create --verify-tag`
  也只允许绑定已存在的 tag。

## 5. 失败了怎么办

| 现象 | 原因 | 处理 |
| --- | --- | --- |
| `validate` 报版本号不一致 | 三处版本号没同步 | 同步后重新打 tag |
| `validate` 报 tag 与版本号不一致 | tag 名与版本号不同 | 删 tag 重打（`git tag -d` + `git push --delete`） |
| `build` 在 `verify-release.sh` 失败 | 架构 / 许可证 / 占位文件 / 公证状态断言不通过 | 看 `verification-report.txt` 的 FAIL 行 |
| `release` 报 Release 已存在 | 同名 Release 已发布 | 换 tag，不覆盖历史产物 |
| `release` 报清单不一致 | manifest 与发布模式不匹配 | 说明产物被误标，必须重新构建 |
| 想发但不想建 Release | — | `workflow_dispatch` + `dry_run=true` |

## 6. 发布后验收清单

- [ ] Actions 全绿，`release` job 显示 Pre-release 已创建
- [ ] Release 标题为 `VideoFlow vX.Y.Z - Test Release` 且带 Pre-release 徽标
- [ ] 6 个资产齐全（见 1.4）
- [ ] `shasum -a 256 -c SHA256SUMS` 全 OK
- [ ] `hdiutil attach` 能挂载，卷内有 `VideoFlow.app` 和 `TEST_RELEASE.txt`
- [ ] 拷贝到 `/Applications` 后能启动，引擎（yt-dlp / ffmpeg / ffprobe）就绪
- [ ] `release-manifest.json` 的 `notarization.status` 是 `NOT_NOTARIZED`，`ticket_stapled` 全 false
