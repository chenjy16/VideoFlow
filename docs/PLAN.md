# VideoFlow 实施计划

## 1. 目标与范围

VideoFlow 是面向 macOS（Apple Silicon 优先）的桌面视频 / 音频下载客户端。它不是"重写一个下载器"，
而是把 **yt-dlp + FFmpeg** 这两个成熟引擎封装成原生体验的应用：负责任务编排、状态管理、持久化、进度呈现与错误诊断。

第一阶段（MVP）只交付一条完整链路：

> 粘贴链接 → 解析真实格式 → 创建任务 → 实时进度 → 取消 → 合并 / 转码 → 完成并打开文件

明确不做：账号体系、云同步、订阅、在线转码、在线视频编辑、社交功能。
也不做：暂停 / 恢复（底层不可靠前，UI 不暴露暂停按钮，更不会把取消伪装成暂停）。

## 2. 技术选型

| 层 | 选择 | 理由 |
| --- | --- | --- |
| 桌面壳 | Tauri 2 | 原生窗口、体积小、Rust 后端可精细控制子进程 |
| 后端 | Rust 2021 + tokio | 子进程生命周期、取消、并发与 IO 处理更可控 |
| 存储 | SQLite（rusqlite，bundled） | 单文件本地库，无需外部服务；WAL 模式 |
| 前端 | React 19 + TypeScript + Vite | 生态成熟，类型贯穿前后端 |
| 样式 | Tailwind CSS v4 + Radix UI | 快速复刻 macOS 观感，组件可访问性由 Radix 保证 |
| 状态 | zustand | 轻量，适合"事件驱动 + 增量合并"的模型 |
| 引擎 | yt-dlp（sidecar）+ FFmpeg | 解析 / 下载 / 合并 / 转码事实标准 |

## 3. 架构分层

```
React UI（页面 / 组件）
   │  invoke(cmd)                  ▲ event: task:updated / task:progress / task:removed
   ▼                              │
Tauri Commands（参数校验、DTO 转换）
   │
   ▼
TaskManager（队列、并发、取消、进度聚合、持久化编排）
   │                    │
   ▼                    ▼
Repository 层（download_repo / settings_repo，唯一 SQL 入口）
   │
   ▼
SQLite（downloads / settings / download_logs）

TaskManager ──► yt-dlp Runner ──► 子进程（独立进程组，可整体取消）──► FFmpeg
```

### 关键约束

- **禁止在业务层写 SQL**：所有读写经由 `storage/` 下的 Repository 函数。
- **禁止 shell 拼接**：`Command` 只用参数数组，不经过 shell。
- **进度只解析结构化数据**：`--progress-template "download:%(progress)j"` 输出的 JSON 行；
  不解析人类可读日志（实测该模板输出不带前缀，直接是 JSON）。
- **成功必须有证据**：`--print-to-file after_move:filepath` 写出的路径存在、是文件、体积 > 0，才标记 `completed`。
- **stdout / stderr 分离读取**，避免管道缓冲死锁；stderr 不一律视为错误（FFmpeg 正常输出也在 stderr）。
- **取消 = 杀整个进程组**：`process_group(0)` + 负 PID 发 SIGINT，超时 8s 后 SIGKILL，杜绝孤儿 ffmpeg。
- **重启后不伪造状态**：启动时把遗留的进行中任务标记为 `interrupted`，不假装仍在后台运行。

## 4. 目录结构

```
src/                     前端
  components/ui/         shadcn 风格基础组件（button/input/select/dialog/…）
  components/layout/     AppShell、Sidebar（Overlay 标题栏拖拽区）
  components/download/   格式选择、媒体摘要
  components/tasks/      TaskCard（状态 + 进度 + 操作）
  pages/                 下载 / 任务 / 历史 / 设置
  store/app.ts           zustand：任务、进度、设置、引擎；事件增量合并
  hooks/                 事件订阅、系统主题
  lib/api.ts             invoke 封装（UI 唯一后端入口）
  types/index.ts         与 Rust serde(camelCase) 对齐的类型
src-tauri/src/
  domain/                媒体信息、任务、设置、错误
  storage/               database + 两个 Repository
  engine/                binaries / inspect / options / progress / runner
  manager/               TaskManager（队列、并发、监控、事件）
  commands/              media / tasks / settings / system
docs/PLAN.md             本文件
```

## 5. 阶段划分与状态

### 阶段一：MVP（进行中）

| 子阶段 | 内容 | 状态 |
| --- | --- | --- |
| 1A | Tauri 2 + React + TS + Tailwind 工程骨架、图标、capabilities | 完成 |
| 1B | Rust 领域模型 + SQLite Repository（downloads / settings / download_logs） | 完成 |
| 1C | yt-dlp 引擎层：解析、选项生成、进度解析、下载运行器、取消、marker 校验 | 完成 |
| 1D | TaskManager：队列、最大并发、状态机、事件推送、重启恢复 | 完成 |
| 1E | Tauri Commands：媒体解析、任务 CRUD、历史、日志、设置、引擎状态 | 完成 |
| 1F | 前端 UI：四个页面 + 全局状态 + 事件订阅 + 加载/空/错误/成功状态 | 完成 |
| 1G | 静态检查、单元测试、真实下载验证 | 完成（`.app` 打包验证待阶段二） |

### 阶段二：后续（未开始）

- 播放列表 / 批量下载
- 下载前后自动执行用户自定义 yt-dlp 参数（高级设置，需白名单校验）
- 带宽限制、分时段限速
- 字幕与封面单独下载
- 真正可靠的暂停 / 恢复（需底层可分片续传且状态可重建，否则不做）
- 菜单栏 / 全局快捷键

## 6. 数据模型

`downloads`：任务全量快照（id、url、title、thumbnail、site、status、kind、selector、format_label、
container、audio_format、output_dir、output_path、total_bytes、downloaded_bytes、speed、eta、
created_at、started_at、completed_at、error_message）。

`selector` 存的是可以直接交给 `yt-dlp -f` 的真实表达式（例如 `30080+30280`），不是 UI 选项 id；
旧版本把 UI 选项 id 存在 `format_id` 列，启动时会自动重命名为 `selector`。

`settings`：key/value 持久化，启动时合并默认值。
`download_logs`：每个任务的诊断日志（已过滤 cookie / authorization 等敏感行）。

## 7. 质量门禁

每次提交前必须全部通过：

```bash
pnpm typecheck          # tsc --noEmit
pnpm lint               # eslint
pnpm format:check       # prettier --check
pnpm build              # tsc + vite build
cargo fmt --check
cargo clippy --all-targets -- -D warnings
cargo test              # 单元测试（不触网）
```

真实链路验证（手动，需联网）：

1. 解析一个真实链接，确认展示的格式来自 `--dump-single-json`，不是写死的 1080p/720p。
2. 选"需合并"的组合下载，观察状态 `downloading → merging → completed`。
3. 下载中点取消，确认进程组被杀、任务为 `cancelled`、无遗留 ffmpeg 进程。
4. 完成后点击"打开文件"，确认文件存在且可播放。
5. 退出应用再启动，确认已完成任务仍在、未完成任务为 `interrupted` 且可重试。

### 1G 实测记录（macOS 26 / Apple Silicon）

环境：yt-dlp 2026.10.26 + ffmpeg 8.0，样例 `https://www.bilibili.com/video/BV1GJ411x7h7`。

| 场景 | 结果 |
| --- | --- |
| 引擎检测 | 设置页显示 yt-dlp / ffmpeg 真实版本 |
| 解析 | 15 个真实格式（1080p/720p/480p/360p × H.264/HEVC/AV1、仅视频、M4A/MP3/WAV） |
| 480p 下载 | `… 852x480.mp4`，26.3 MB，ffprobe：h264 852×480 + aac，212.3s |
| 1080p 下载 | `… 1920x1080.mp4`，75.2 MB，ffprobe：h264 1920×1080 + aac |
| 同清晰度重复下载 | 覆盖同名文件并真实重下（mtime 与进度均更新） |
| 取消 | 状态 `cancelled`，`pgrep yt-dlp/ffmpeg` 为空，无 `.part` 残留 |
| 音频提取 | `… .mp3`，6.9 MB，ffprobe：mp3 audio，212.3s |
| 重启恢复 | 已完成任务全部回显，可打开文件 / 定位 / 重下 |
| 崩溃恢复 | 残留 `downloading` 任务在启动时纠正为 `interrupted`，UI 显示「已中断」并提供重试 |

验证中修复的两个真实缺陷：

1. 前端把 UI 选项 id（`v-480-h264`）当作 `-f` 表达式传后端 → `Requested format is not available`。
   修复：字段语义改为 `selector`，只接受真实 `format_id` 组合。
2. 输出模板不含清晰度，同名文件被 yt-dlp 跳过并回显旧路径 → 未真正下载却显示成功。
   修复：视频模板加入 `%(resolution)s`、音频单独模板、`--force-overwrites`，
   并在完成校验中要求输出文件 mtime 不早于本次启动（双重下限防伪）。

## 8. 已知风险与对策

| 风险 | 对策 |
| --- | --- |
| yt-dlp 随站点频繁失效 | sidecar 固定版本 + 设置页展示版本，后续提供更新入口 |
| 大文件下载磁盘占用 | 只信任真实文件大小，UI 明确显示预计体积 |
| 缩略图 / CDN 请求被 CSP 拦截 | CSP 允许 `img-src https:`，仅用于展示 |
| 用户输入恶意 URL | 仅接受 http/https，参数数组传参，`--paths` 目录强校验，禁止 `..` |
| 取消后残留进程 | 进程组 + SIGINT → SIGKILL 兜底 + 退出时统一 shutdown |
| 日志泄漏凭据 | 写入日志前过滤 `cookie` / `authorization` 行 |

## 9. 合规声明

本应用不绕过 DRM、不破解付费墙，不做内容再分发。请仅下载你有权保存的内容，并遵守目标站点服务条款。

## 10. macOS Release 构建与发布验证（2026-11-14）

本轮不新增功能、不改动已验证的下载核心逻辑，只做打包与发布级验证。

### 10.1 打包架构审查结论

| 项 | 结论 |
| --- | --- |
| `tauri.conf.json` | `bundle.targets ["app","dmg"]`、`externalBin ["binaries/yt-dlp"]`、`minimumSystemVersion 11.0` |
| bundle.category | 原 `PublicDomain` 不是合法枚举，直接导致打包器报 `failed to build bundler settings: invalid category`；改为 `Video` 后构建通过（配置修复，非业务逻辑改动） |
| sidecar 落地 | `binaries/yt-dlp-aarch64-apple-darwin` → `VideoFlow.app/Contents/MacOS/yt-dlp`（可执行位 0755） |
| yt-dlp 解析顺序 | `current_exe` 同级 → `CARGO_MANIFEST_DIR/binaries`（开发路径被编译进 release 二进制，但排序上被 sidecar 遮蔽）→ `/opt/homebrew/bin` 等常见路径 → `PATH`；支持 `VIDEOFLOW_YTDLP_PATH` / `FFMPEG_PATH` 覆盖 |
| FFmpeg | **未随包分发**，运行时取 `/opt/homebrew/bin/ffmpeg` |
| 数据目录 | `~/Library/Application Support/app.videoflow.desktop/videoflow.db`；日志 `~/Library/Logs/app.videoflow.desktop/VideoFlow.log`；缓存 `~/Library/Caches/app.videoflow.desktop`；默认下载目录 `~/Downloads/VideoFlow` |
| opener / dialog / notification / log | 均在 `capabilities/default.json` 中以 `default` 权限集授权 |

### 10.2 构建产物

命令：`APPLE_SIGNING_IDENTITY="Developer ID Application: jianyu chen (HQC33J8U5Y)" pnpm tauri build`

| 产物 | 路径 | 大小 | 架构 |
| --- | --- | --- | --- |
| .app | `src-tauri/target/release/bundle/macos/VideoFlow.app` | 51 MB | 主程序 arm64 |
| .dmg | `src-tauri/target/release/bundle/dmg/VideoFlow_0.1.0_aarch64.dmg` | 42 MB | 内含同一 .app |
| sidecar | `Contents/MacOS/yt-dlp` | 37.2 MB | universal（x86_64 + arm64） |

- 仅生成与验证了 Apple Silicon（arm64）产物，未出 Intel / universal 构建。
- `Info.plist`：`app.videoflow.desktop` / `0.1.0` / `LSMinimumSystemVersion 11.0` / `public.app-category.video`。
- `.app` 内除主程序与 sidecar 外只有 `Resources/icon.icns`，无任何第三方许可证声明文件。
- sidecar 体积 36MB，**不纳入版本库**（`.gitignore` 已忽略 `src-tauri/binaries/`）；首次构建前执行 `./scripts/fetch-yt-dlp.sh`，脚本按固定版本 `2026.10.26` 与 sha256 校验下载。

### 10.3 签名、Hardened Runtime 与公证

| 项 | 状态 |
| --- | --- |
| Developer ID Application | `jianyu chen (HQC33J8U5Y)`，app 与嵌套 yt-dlp 均已签名，带 Timestamp |
| Hardened Runtime | 启用（`flags=0x10000(runtime)`） |
| Entitlements | `src-tauri/entitlements.plist`：`com.apple.security.cs.disable-library-validation` |
| `codesign --verify --deep --strict` | 通过（退出码 0） |
| 公证 | **未做**：环境无 `APPLE_ID` / `APPLE_PASSWORD` / `APPLE_TEAM_ID` / `APPLE_API_KEY`，`notarytool` 无可用 keychain profile，Tauri 打印 `Warn skipping app notarization` |
| 装订票据 | `xcrun stapler validate` → `does not have a ticket stapled to it` |
| Gatekeeper | `spctl -a -vv --type execute` → `rejected` / `source=Unnotarized Developer ID`（退出码 3） |

**签名后暴露的真实缺陷（已修复）**：yt-dlp 以 PyInstaller onefile 分发，运行时会把内嵌 `Python.framework`（Python 3.14）解压到临时目录再 `dlopen`；该 framework 携带上游签名，Team ID 与应用不同，开启 Hardened Runtime 后被 library validation 拒绝，sidecar 直接 `exit=255`，日志里版本号显示 `(unknown)`。

修复：新增 `src-tauri/entitlements.plist` 关闭 library validation，并在 `tauri.conf.json` 的 `bundle.macOS` 中设置 `hardenedRuntime: true` + `entitlements: "entitlements.plist"`。修复后 `codesign -d --entitlements` 显示 app 与 sidecar 均带该权限，在 DMG 挂载路径下执行 `Contents/MacOS/yt-dlp --version` → `2026.10.26`，退出码 0。

### 10.4 独立运行验证（从 DMG 挂载路径启动）

| 验证项 | 结果 |
| --- | --- |
| 启动 | `open /Volumes/VideoFlow/VideoFlow.app` 成功，进程为 `/Volumes/…/Contents/MacOS/videoflow` |
| 引擎探测 | 日志 `yt-dlp: /Volumes/VideoFlow/VideoFlow.app/Contents/MacOS/yt-dlp (2026.10.26)`；`ffmpeg: /opt/homebrew/bin/ffmpeg (8.0)` |
| 解析 / 格式列表 | 正常返回真实格式（1080p/720p/480p/360p × H.264/HEVC/AV1、M4A/MP3/WAV） |
| 480p 下载 | 完成，26,347,813 B，文件名 `… 852x480.mp4` 覆盖旧文件（mtime 更新） |
| FFmpeg 合并 | 该次下载使用 `-f 30032+30280`，产物 ffprobe：h264 852×480 + aac，212.3s |
| 音频提取 | 完成，6,907,813 B，ffprobe：mp3 audio，212.3s |
| 取消 | 1080p 任务点「取消」→ UI「已取消」，DB `cancelled`，无残留 yt-dlp/ffmpeg，无 `.part` |
| 数据库 / 重启 | 退出再启动，历史页显示 `14 条记录`，与 DB（completed 10 / cancelled 3 / failed 1）一致 |
| 通知 | NotificationCenter 已收到 `app.videoflow.desktop` 通知记录，但 `usernoted` 记录 `authorizationStatus: Denied`、`Authorization set for app.videoflow.desktop to allow: NO`，未出现可见横幅 |

### 10.5 文件操作验证

| 场景 | 结果 |
| --- | --- |
| 打开文件 | 点按后 IINA 以新进程启动，窗口标题为对应文件名（`.mp3`） |
| 在 Finder 中显示 | Finder 前台窗口为 `~/Downloads/VideoFlow/`，选中项为含中文与【】的文件名 |
| 中文/【】文件名 | 全链路正常（下载、DB、UI、Finder、播放器） |
| 文件不存在 | UI 显示「文件已被移动或删除，无法打开」，应用保持运行不崩溃 |

### 10.6 许可证审查结论

| 组件 | 版本 | 许可证 |
| --- | --- | --- |
| yt-dlp | 2026.10.26 | Unlicense |
| 内嵌 CPython | 3.14.7 | PSF-2.0 |
| PyInstaller bootloader | 6.x | GPL-2.0-or-later（带打包例外） |
| Cryptodome / brotli / certifi | 3.24.1 / 1.2.1 / 2026.10.23 | Public Domain+BSD-2 / MIT / MPL-2.0 |
| curl_cffi / cffi / pycparser | 0.17.0 / 2.1.1 / 3.12 | MIT / MIT-0 / BSD-3-Clause |
| mutagen | 1.48.1 | **GPL-2.0-or-later** |
| requests / charset-normalizer / idna / urllib3 / websockets | 2.34.2 / 3.5.2 / 3.20 / 2.8.0 / 17.3 | Apache-2.0 / MIT / BSD-3 / MIT / BSD-3-Clause |
| sqlite3 / OpenSSL / libffi | 3.50.4 / 3.5.7 / — | Public Domain / Apache-2.0 / MIT |
| FFmpeg（未随包） | 8.0 Homebrew | **GPLv3**（`--enable-gpl --enable-version3`） |
| Tauri | 2.x | MIT / Apache-2.0 |
| React | 19.x | MIT |
| npm 依赖 | — | MIT 24 / ISC 1 / Apache-2.0 2 / MIT OR Apache-2.0 5 |
| Rust 依赖（493 crates） | — | MIT OR Apache-2.0 211、MIT 128、Apache-2.0 OR MIT 53、Unicode-3.0 18、Zlib 组合 17、Unlicense OR MIT 9、**MPL-2.0 7**（cssparser×2、cssparser-macros、selectors×2、dtoa-short、option-ext）、BSD-3 2 等 |

商业分发注意事项：

1. yt-dlp 保持「未修改的独立可执行文件 + 子进程调用」，不要静态链接进主程序；随包附带其 `THIRD_PARTY_LICENSES.txt` 与 Unlicense 文本。上游二进制内已包含 mutagen（GPL-2.0-or-later），分发未修改的上游产物并提供对应源码即可满足义务。
2. FFmpeg 目前只调用用户机器上的 Homebrew 版本，干净机器上合并/音频提取会失败。要随包分发时二选一：捆绑 `--disable-gpl` 的 LGPL 构建（不能含 x264/x265），或捆绑 GPL 构建并履行 GPLv3（提供源码、许可证、可替换性）。GPL 与 Mac App Store 条款冲突，建议 Developer ID 直接分发。
3. Apache-2.0（Tauri 等）需保留 LICENSE/NOTICE；MIT 需保留版权与许可声明；MPL-2.0 crates 只在修改其文件时才需公开该文件；Unicode-3.0 需署名。
4. 当前 `.app` 未打包任何第三方声明文件，正式分发前应把 `cargo-about`/`cargo-license` 生成的清单与 yt-dlp 的 `THIRD_PARTY_LICENSES.txt` 放入 bundle resources。

### 10.7 质量门禁（本轮实测，含退出码）

| 命令 | 退出码 | 结果 |
| --- | --- | --- |
| `pnpm typecheck` | 0 | 无类型错误 |
| `pnpm lint` | 0 | 无 ESLint 报告 |
| `pnpm format:check` | 0 | 全部匹配 Prettier |
| `pnpm build` | 0 | 2199 modules，CSS 38.52 kB / JS 449.28 kB |
| `cargo fmt --check` | 0 | 无差异 |
| `cargo clippy --all-targets -- -D warnings` | 0 | 无告警 |
| `cargo test` | 0 | 32 passed / 0 failed |

### 10.8 仍未完成 / 需人工处理

| 项 | 状态 |
| --- | --- |
| FFmpeg 随包 | 未实现（依赖用户机器 Homebrew） |
| 公证 | 需用户提供 Apple ID + app-specific password（或 App Store Connect API Key）后执行 `notarytool submit` + `stapler staple` |
| Gatekeeper 首次打开 | 未公证前用户需右键打开或 `xattr -d com.apple.quarantine` |
| 通知横幅 | 系统当前为 Denied，需用户在「系统设置 › 通知 › VideoFlow」中允许 |
| Intel / universal 构建 | 未生成、未验证 |
| 第三方许可证声明文件 | 未随包 |
| 自动更新 | 未实现 |

