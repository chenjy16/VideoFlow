# CI/CD 结构

VideoFlow 的 CI 分三个独立的 workflow，职责互不重叠：质量门禁、发布、FFmpeg 构建。
发布流程的操作手册见 [RELEASE.md](./RELEASE.md)，实测记录见 [CI_CD_REPORT.md](./CI_CD_REPORT.md)。

## 1. Workflow 总览

| 文件 | 触发 | 职责 | 写权限 |
| --- | --- | --- | --- |
| `.github/workflows/ci.yml` | PR / push main / 手动 | 门禁静态测试 + 前端质量 + Rust 质量 | 无（`contents: read`） |
| `.github/workflows/release.yml` | `v*` tag / 手动 | 构建 → 校验 → 打包 → （tag）创建 Pre-release | 仅 `release` job（`contents: write`） |
| `.github/workflows/ffmpeg-lgpl.yml` | 被 release 调用 / 手动 | 构建 LGPL 版 ffmpeg/ffprobe + 许可证与再链接材料 | 无（`contents: read`） |

权限原则：**workflow 级一律只读，只有 release job 单独申请 `contents: write`**。
`ci.yml` 完全不引用 `secrets.*`，因此 fork 的 PR 拿不到任何凭据。

## 2. ci.yml

| job | 内容 | 超时 |
| --- | --- | --- |
| `release-gating` | 运行 `scripts/test-release-gating.sh`（静态解析 release.yml + 脚本断言） | 10 min |
| `frontend` | `pnpm typecheck` / `lint` / `format:check` / `build` | 20 min |
| `rust` | `cargo fmt --check` / `clippy -D warnings` / `test` | — |

`release-gating` 是发布逻辑的**回归护栏**：它直接读 `release.yml` 里真实的表达式和 run 块，
在 Ruby 里按 GitHub 的真值语义求值，因此改坏条件表达式会立刻在 PR 阶段暴露。

它守住的三条底线：

1. `internal_build=true` 永不创建 Release；
2. tag 推送只走 unsigned 测试发行（Pre-release），且不需要任何 Apple 凭据；
3. 真实签名 / 公证路径的凭据门禁（3/3 或全空、tag 必须可公证）不被削弱。

## 3. release.yml

### 3.1 三种模式（由触发方式唯一决定）

| 模式 | 触发 | `INTERNAL_BUILD` | `TEST_RELEASE` | `REQUIRE_NOTARIZATION` | Release |
| --- | --- | --- | --- | --- | --- |
| internal | `workflow_dispatch` + `internal_build=true` | `true` | `false` | `false` | 不创建 |
| test | 推送 `v*` tag | `false` | `true` | `false` | **Pre-release** |
| signed | `workflow_dispatch`（其它） | `false` | `false` | `true` | 正式版（需凭据） |

对应的表达式（`env`）：

```yaml
INTERNAL_BUILD:       ${{ github.event_name == 'workflow_dispatch' && inputs.internal_build && 'true' || 'false' }}
TEST_RELEASE:         ${{ github.ref_type == 'tag' && 'true' || 'false' }}
REQUIRE_NOTARIZATION: ${{ (github.ref_type == 'tag' || (github.event_name == 'workflow_dispatch' && inputs.internal_build)) && 'false' || 'true' }}
```

### 3.2 job 拓扑

```
validate ──┬── ffmpeg ── build ──┐
           └──────────────────────┴── release（仅 tag + 全部成功）
```

| job | 权限 | 关键步骤 |
| --- | --- | --- |
| `validate` | 只读 | arm64 校验、三处版本号一致、tag 形态（`v<version>` / `v<version>-test.<N>`）、签名模式判定、公证凭据判定 |
| `ffmpeg` | 只读 | 调用 `ffmpeg-lgpl.yml` |
| `build` | **只读** | 依赖安装、Rust 校验、取回 LGPL 产物、yt-dlp 校验、`tauri build`、公证（仅 signed）、`verify-release.sh`、`package-release.sh`、上传 Artifact |
| `release` | `contents: write` | 下载候选产物、`shasum -c`、manifest 复核、票据断言、拒绝覆盖、`gh release create` |

### 3.3 三种产物名（不允许串用）

| 模式 | Artifact 名 |
| --- | --- |
| internal | `videoflow-internal-test-<version>-<short_sha>` |
| test | `videoflow-test-release-<version>-<short_sha>` |
| signed | `videoflow-signed-notarized-<version>` / `videoflow-internal-unsigned-<version>` |

### 3.4 门禁分工

| 脚本 | 职责 |
| --- | --- |
| `scripts/import-signing-certificate.sh` | 临时 keychain 导入 Developer ID 证书（仅 signed） |
| `scripts/notarize.sh` | submit → 只认 Apple 返回的 `Accepted` → staple → validate（仅 signed） |
| `scripts/verify-release.sh` | 架构 / 引擎 / 许可证 / 签名 / 公证状态逐项断言，输出 `verification-report.txt` |
| `scripts/package-release.sh` | 命名、DMG 卷内标记、manifest、`SHA256SUMS` |
| `scripts/generate-checksums.sh` | 对最终文件生成 `SHA256SUMS` |
| `scripts/fetch-yt-dlp.sh` | 固定版本 + SHA256 校验 |
| `scripts/verify-ffmpeg-lgpl.sh` | LGPL 产物与许可证材料复核 |
| `scripts/test-release-gating.sh` | 纯静态回归测试（CI 与本地都跑） |

## 4. Secrets

当前仓库**不配置任何 Apple Secrets**，tag 与 internal 两条路径都不读取它们。

| Secret | 用到的地方 | 当前状态 |
| --- | --- | --- |
| `APPLE_CERTIFICATE` / `APPLE_CERTIFICATE_PASSWORD` / `APPLE_SIGNING_IDENTITY` | 仅 signed 模式 | 未配置 |
| `APPLE_API_KEY` / `APPLE_API_ISSUER` / `APPLE_API_KEY_P8_BASE64` | 仅 signed 模式的公证步骤 | 未配置 |
| `GITHUB_TOKEN` | `release` job 创建 Release | 自动注入 |

## 5. 本地复现

```bash
# 发布门禁回归测试（与 ci.yml 的 release-gating 完全一致）
./scripts/test-release-gating.sh

# 前端 / Rust 质量门禁
pnpm typecheck && pnpm lint && pnpm format:check && pnpm build
cd src-tauri && cargo fmt --check && cargo clippy --all-targets -- -D warnings && cargo test
```

手动触发内部构建：

```bash
gh workflow run release.yml -f dry_run=true -f internal_build=true
gh run list --workflow=release.yml --limit 3

# 下载 Artifact（需要 gh + 已登录）
gh run download <run-id> -n videoflow-internal-test-0.1.0-<sha>
```

## 6. 常见失败与定位

| 现象 | 位置 | 排查 |
| --- | --- | --- |
| `发布门禁静态测试` 失败 | ci.yml / release-gating | 本地跑同一脚本，失败行会指出具体断言 |
| `三处版本号不一致` | validate | 同步 package.json / tauri.conf.json / Cargo.toml |
| `tag ... 与版本号 ... 不一致` | validate | 只允许 `v<version>` 或 `v<version>-test.<N>` |
| `签名 Secrets 只配置了 N/3` | validate | 三个必须全部配置或全部留空 |
| `公证凭据只配置了 N/3` | validate | 同上，适用于 signed 模式 |
| `REQUIRE_NOTARIZATION 必须为 true` | validate | signed 模式下不允许关掉公证要求 |
| `TEST_RELEASE 与 INTERNAL_BUILD 互斥` | validate | 两种模式不能同时开启（理论上触发方式已互斥） |
| DMG 内没有 `TEST_RELEASE.txt` | build / package-release | 写标记失败会直接 `die`，看是否有 `hdiutil` 错误 |
| `Release ... 已存在` | release | 项目不覆盖历史产物，需换 tag |
| 清单校验失败 | release | manifest 与发布模式不匹配，必须重新构建 |

## 7. 与 Phase 历史的关系

| Phase | 内容 | 现状 |
| --- | --- | --- |
| Phase 3 | CI 签名接入（Developer ID） | 代码保留，凭据未配置 |
| Phase 4 | Apple 公证接入（Team API Key + staple） | 代码保留，仅在 signed 模式执行 |
| Phase 5 | `internal_build` 内部测试构建（只出 Artifact） | 已实测通过 |
| Phase 6 | 推送 `v*` tag → unsigned 测试发行 Pre-release | 本轮实现 |

Phase 4 的公证实现（`notarize.sh` 与 `verify-release.sh` 的票据 / `ACCEPTED` 断言）没有被删除或放宽，
只是在 tag / internal 模式下被 `if` 跳过。
