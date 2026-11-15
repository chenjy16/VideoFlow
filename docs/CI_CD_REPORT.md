# CI/CD 实测报告

本文件记录发布流水线的**真机实测结果**，不做设计说明。
设计说明见 [CI_CD.md](./CI_CD.md)，操作手册见 [RELEASE.md](./RELEASE.md)，签名与公证见 [NOTARIZATION.md](./NOTARIZATION.md)。

仓库：`chenjy16/VideoFlow`　运行环境：GitHub Actions `macos-15`（Apple Silicon）

---

## 1. 当前发布模式（Phase 6 结论）

| 模式 | 触发 | 产物 | Release | 需要 Apple 凭据 |
| --- | --- | --- | --- | --- |
| internal | `workflow_dispatch` + `internal_build=true` | Actions Artifact | **不创建** | 不需要 |
| **test** | 推送 `v*` tag | GitHub **Pre-release** | **创建（prerelease）** | **不需要** |
| signed | `workflow_dispatch`（其它） | 正式 Release | 创建 | 需要 6 个 Secrets |

> 当前项目**没有也不计划申请** Apple Developer Program，因此对外分发走 test 模式：
> unsigned、notarization-free 的测试发行版，明确标注 `TEST RELEASE - UNSIGNED - NOT NOTARIZED`。
> `signed` 路径的代码（`import-signing-certificate.sh` / `notarize.sh` / 票据与 `ACCEPTED` 断言）完整保留，只是未启用。

---

## 2. Phase 6 实跑记录

Phase 6 一共推了 3 个 tag，都是为了在**不占用正式版本号**的前提下验证流水线
（`v0.1.0-test.<N>` 形式由 `validate` 的 tag 形态校验显式允许）。

| tag | commit | Run ID | 结果 | 说明 |
| --- | --- | --- | --- | --- |
| `v0.1.0-test.1` | `e5ed952` | [43690494221](https://github.com/chenjy16/VideoFlow/actions/runs/43690494221) | **失败** | `build` 在 `pnpm tauri build` 打包 DMG 时报 `hdiutil: create failed - Resource busy` |
| `v0.1.0-test.2` | `4e28bb1` | [43690896699](https://github.com/chenjy16/VideoFlow/actions/runs/43690896699) | 成功 | 全链路闭环，但 `SHA256SUMS` 含未分发的 `TEST_RELEASE.txt` |
| `v0.1.0-test.3` | `e88c931` | [43692793949](https://github.com/chenjy16/VideoFlow/actions/runs/43692793949) | **成功（当前推荐）** | 缺陷修复后复跑，全部验收项通过 |

对应 `ci.yml` 三次运行均 success（`43690485246` / `43690892133` / `43692789795`）。

### 2.1 两个真实失败与修复

**失败 1：`hdiutil: create failed - Resource busy`（test.1）**

Tauri 的 `bundle_dmg.sh` 用 `hdiutil` 挂载临时镜像，runner 上偶发资源占用。
这不是构建错误，但会让整条流水线失败。修复：`release.yml` 的构建步骤外层加
`cleanup_dmg()`（detach 残留 `/Volumes/VideoFlow*`、`rm -rf bundle/dmg`）+ 最多 1 次重试。
重试时 Rust 与前端产物已在 `target/` 缓存，代价很小。test.2 起未再复现。

**失败 2：`SHA256SUMS` 指向下载不到的文件（test.2）**

`package-release.sh` 先在发布目录生成 `TEST_RELEASE.txt`，再把它写进 DMG 卷内，
但**生成后没有清理**，于是 `generate-checksums.sh` 把它也算了进去。
用户实测报错：

```
$ shasum -a 256 -c SHA256SUMS
TEST_RELEASE.txt: No such file or directory
```

修复：写进 DMG 后从发布目录 `rm -f`（internal 模式的 `INTERNAL_TEST_BUILD.txt` 同样处理），
并补上 gating 断言防止回退。Release 资产仍是 6 个，`SHA256SUMS` 只覆盖真正分发的 5 个文件。

`v0.1.0-test.2` 的 Release Notes 已追加缺陷警告并指向 test.3，**历史产物不删除、不覆盖**。

### 2.2 test.3 的 job 时序

| job | 耗时 | 结论 |
| --- | --- | --- |
| 校验版本与发布条件 | 8 s | success（无 Apple Secrets，未被拦截） |
| 构建 FFmpeg LGPL | 18 s | success（命中缓存） |
| 构建 / 签名 / 公证 / 校验 / 打包 | 3 min 07 s | success（签名与公证步骤被 `if` 跳过） |
| 创建 GitHub Release | 21 s | success（Pre-release） |

总计约 4 分钟。

---

## 3. 发布产物（v0.1.0-test.3）

Release：<https://github.com/chenjy16/VideoFlow/releases/tag/v0.1.0-test.3>

- 标题：`VideoFlow v0.1.0-test.3 - Test Release`
- `isPrerelease: true`，`isDraft: false`
- 发布时间：2026-11-15T08:08:34Z

### 3.1 资产清单（6 个）

| 文件 | 大小（字节） |
| --- | --- |
| `VideoFlow_0.1.0_aarch64_TEST-UNSIGNED.dmg` | 52,995,706 |
| `VideoFlow_0.1.0_aarch64_TEST-UNSIGNED.app.zip` | 50,388,054 |
| `SHA256SUMS` | 481 |
| `release-manifest.json` | 1,602 |
| `THIRD_PARTY_LICENSES.md` | 17,158 |
| `SOURCE_OFFER.txt` | 5,843 |

`verification-report.txt` 只随 Actions Artifact 保留，不进 Release。

### 3.2 SHA256

DMG 下载地址：
<https://github.com/chenjy16/VideoFlow/releases/download/v0.1.0-test.3/VideoFlow_0.1.0_aarch64_TEST-UNSIGNED.dmg>

```
f3ce34149cd49b287976da78313b159d3edfcac904ec9cce34d63894ec0eaa88  VideoFlow_0.1.0_aarch64_TEST-UNSIGNED.dmg
74593199fb01e5df7827b323624f86654cb0edee3f9e80710293d852abf55cb2  VideoFlow_0.1.0_aarch64_TEST-UNSIGNED.app.zip
4655d007af7d87db2d74cdde3cffa25044703d64090afee52943121c96c07ea3  SOURCE_OFFER.txt
2b4a5249e8e7520acb045277352fc56676113df94080b4bef3127748e4b675b1  THIRD_PARTY_LICENSES.md
a6b8c22947062ed92950f16b3cf896b1b72ced86e86590b25be8668cbe308be3  release-manifest.json
```

`SHA256SUMS` 内容与上面 5 行**完全一致**，不再出现 `TEST_RELEASE.txt`。

### 3.3 manifest 关键字段

```json
{
  "tag": "v0.1.0-test.3",
  "commit": "e88c931ad69ed8bb2b32762474738fa636f99da5",
  "build_kind": "test-release",
  "distribution_notice": "TEST RELEASE - UNSIGNED - NOT NOTARIZED",
  "dmg_inner_marker": true,
  "signing": { "mode": "unsigned", "identity": null, "team_id": null,
               "hardened_runtime": false, "dmg_signed": false },
  "notarization": { "method": "none", "tool": "none", "status": "NOT_NOTARIZED",
                    "submission_id": "", "required": false,
                    "ticket_stapled": { "dmg": false, "app": false } },
  "engines": { "yt-dlp": "2026.10.26", "ffmpeg": "8.0.1", "ffprobe": "8.0.1" }
}
```

---

## 4. 下载与安装验证（本机实跑）

全部在真实 macOS（Apple Silicon）上完成，不是 CI 内的模拟。

| 步骤 | 命令 | 结果 |
| --- | --- | --- |
| 干净目录下载 | `gh release download v0.1.0-test.3 -D <dir>` | 6 个文件，大小与 Release 一致 |
| 校验和 | `shasum -a 256 -c SHA256SUMS` | **5 项全部 OK**，exit 0 |
| 镜像完整性 | `hdiutil verify <dmg>` | `checksum ... is VALID` |
| 挂载 | `hdiutil attach -nobrowse -readonly` | 挂载到 `/Volumes/VideoFlow` |
| 卷内标记 | `cat /Volumes/VideoFlow/TEST_RELEASE.txt` | 首行 `TEST RELEASE - UNSIGNED - NOT NOTARIZED`，含 version / commit / tag / 构建时间 |
| DMG 签名 | `codesign -dv <dmg>` | `code object is not signed at all` |
| App 签名 | `codesign -dv VideoFlow.app` | `Signature=adhoc`、`flags=0x20002(adhoc,linker-signed)`、`TeamIdentifier=not set`、**无 `Authority=Developer ID Application`** |
| 票据 | `xcrun stapler validate <dmg>` | `does not have a ticket stapled to it`（符合预期） |
| Gatekeeper | `spctl -a -vv VideoFlow.app` | `rejected`（未签名未公证的预期行为） |
| 架构 | `lipo -archs .../MacOS/VideoFlow` | `arm64` |
| 安装 | `ditto` 到 `/Applications`，清除 quarantine | 成功 |
| 启动 | `open -a /Applications/VideoFlow.app` | 进程存活（pid 5978），主窗口渲染正常，底部显示「引擎就绪 yt-dlp 2026.10.26」 |
| 退出 | `osascript -e 'quit app "VideoFlow"'` | 正常退出，卷已 detach |

**结论**：DMG 可挂载、可安装、可启动，引擎（yt-dlp / ffmpeg / ffprobe）就绪；
产物确实**未签名、未公证、无票据**，与 manifest、卷内标记、Release Notes 四处的声明一致。

---

## 5. 自动化门禁

### 5.1 发布门禁回归测试

```
$ ./scripts/test-release-gating.sh
...
小计: PASS=76 FAIL=0
发布门禁回归测试全部通过
```

覆盖用户要求的 14 个场景，包括：tag + 无 Secrets 允许进入 unsigned 构建、不得调用公证、
`ALLOW_UNSIGNED=1`、`REQUIRE_NOTARIZATION=false`、manifest `NOT_NOTARIZED`、
DMG 内 `TEST_RELEASE.txt`、构建/校验失败不建 Release、`internal_build` 不建 Release、
拒绝覆盖同名 Release，以及**伪造 `NOTARIZATION_STATUS=ACCEPTED` 必须被拒**
（`verify-release.sh` 与 `package-release.sh` 两层都会拦截）。

Phase 4 对真实公证状态与 Staple 票据的断言**未放宽**：gating 里仍有反向用例，
证明已签名的包在无票据时依然会被判 FAIL。

### 5.2 其它门禁（本地全通过）

| 检查 | 结果 |
| --- | --- |
| `bash -n` 三个 workflow 的全部 46 个 `run` 块 | 通过 |
| YAML 解析（ci / release / ffmpeg-lgpl） | 通过；`contents: write` 只出现在 `release` job |
| `pnpm typecheck` / `lint` / `format:check` / `build` | 通过 |
| `cargo fmt --check` / `clippy -D warnings` / `test` | 通过 |

---

## 6. 尚未完成 / 已知限制

| 项目 | 状态 | 说明 |
| --- | --- | --- |
| Developer ID 签名 + Apple 公证的正式发行 | **未验证** | 无 Apple Developer Program 账号，本轮不做；代码路径保留 |
| `signed` 模式真实创建正式 Release | **未验证** | 需配齐 6 个 Secrets 后手动 dispatch |
| Gatekeeper 首次打开的完整用户体验 | **部分验证** | 已验证 `spctl` 拒绝与手动去隔离后启动成功，未在全新机器上从零走一遍 |
| `v0.1.0-test.1` 的 Release | 不存在 | 该次构建在 `build` 阶段失败，未创建 Release（符合预期） |
| `v0.1.0-test.2` | 有已知缺陷 | `SHA256SUMS` 多一行，已在 Notes 标注，请用 test.3 |
| Intel（x86_64）产物 | 不支持 | 流水线与 `validate` 均硬性限定 `aarch64-apple-darwin` |
| 版本号 | 仍为 `0.1.0` | 正式对外发版前需同步三处版本号并更新 CHANGELOG |

---

## 7. 复现命令

```bash
# 本地门禁
./scripts/test-release-gating.sh

# 推一个测试 tag（不占用正式版本号）
git tag v0.1.0-test.4 && git push origin v0.1.0-test.4
gh run watch

# 下载并校验
gh release download v0.1.0-test.4 -D /tmp/vf && cd /tmp/vf && shasum -a 256 -c SHA256SUMS

# 挂载检查
hdiutil attach VideoFlow_0.1.0_aarch64_TEST-UNSIGNED.dmg -nobrowse -readonly
cat /Volumes/VideoFlow/TEST_RELEASE.txt
xcrun stapler validate VideoFlow_0.1.0_aarch64_TEST-UNSIGNED.dmg   # 预期：无票据
hdiutil detach /Volumes/VideoFlow
```
