# Release Hardening 报告（FFmpeg 静态 LGPL + yt-dlp entitlement 决策）

日期：2026-11-15　产品版本：VideoFlow 0.1.0（macOS arm64）　证书：`Developer ID Application: jianyu chen (HQC33J8U5Y)`

本轮依据两项用户决策执行：

1. **FFmpeg 采用静态 LGPL 构建**（不用动态链接），并要求不以 `--disable-gpl` 作为唯一合规依据；
2. **yt-dlp 保留 onefile 与现有 entitlement**，只补文档，不为去 entitlement 破坏功能。

执行顺序按要求为：**先完成 FFmpeg 构建方案与许可证审计，再实施代码修改**。

---

## 0. 总结论

| 维度 | 结论 |
| --- | --- |
| FFmpeg 静态 LGPL 构建 | **PASS**：8.0.1，8.0 MB / 7.8 MB，仅依赖系统库 |
| 许可证审计（是否含 GPL） | **PASS**：7 组独立证据均指向“无 GPL/GPLv3 组件” |
| LGPL 静态链接义务 | **PASS**（材料齐备）：许可证文本 + 固定源码 + 589 `.o` + 8 `.a` + 构建脚本 + 3 年书面要约 |
| 代码集成（随包三引擎） | **PASS**：发布版只认内置 sidecar，缺引擎时硬拦截 |
| 质量门禁 | **PASS**：Rust 34 tests、clippy/fmt、typecheck/lint/format/build 全部退出码 0 |
| 签名 Release 构建 + DMG | **PASS**：`codesign --verify --deep --strict` 通过，DMG 挂载内自检通过 |
| 隔离环境运行与功能验证 | **PASS**：`env -i` + 仅系统 PATH，三引擎路径正确，合并/6 种音频格式全部成功 |
| yt-dlp 在签名环境可用 | **PASS**：随包 yt-dlp + 随包 ffmpeg 完成一次真实下载合并 |
| 公证 | **BLOCKED**：环境无 Apple 凭据，未执行 `notarytool`，不声称完成 |
| 设置页「第三方许可证」按钮点击 | **NOT TESTED**：UI 自动化被前台窗口抢占，未能真实点击 |
| Intel / universal | 未构建（沿用既有范围） |

没有出现“静态 LGPL 方案无法满足技术或许可证要求”的情况，因此**没有**改用 GPL 构建。

---

## 1. 变更清单

### 1.1 新增

| 文件 | 说明 |
| --- | --- |
| `scripts/build-ffmpeg-lgpl.sh` | FFmpeg 8.0.1 + LAME 3.100 + libopus 1.5.2 的可复现静态 LGPL 构建；固定版本 + sha256；内置 GPL 开关断言；`KEEP_OBJECTS=1` 产出再链接材料 |
| `licenses/SOURCE_OFFER.txt` | LGPL v2.1 §6c / GPL v2 §3 书面要约、源码地址与哈希、再链接与重签步骤、3 年有效期 |
| `licenses/FFmpeg-LGPL-2.1.txt` | LGPL v2.1 全文 |
| `licenses/FFmpeg-LICENSE.md` | FFmpeg 上游许可证说明 |
| `licenses/LAME-LGPL-2.0.txt` | LAME 许可证全文 |
| `licenses/libopus-BSD-3-Clause.txt` | libopus 许可证全文 |
| `licenses/yt-dlp-THIRD_PARTY_LICENSES.txt` | 从 yt-dlp 二进制归档中提取的官方第三方清单（243,550 B） |
| `docs/THIRD_PARTY_LICENSES.md` | 组件清单 + LGPL 义务逐条落地 + 取证过程 |
| `docs/NOTARIZATION.md` | 签名/entitlement 决策、安全影响、公证 BLOCKED 与操作模板 |
| `docs/RELEASE_HARDENING_REPORT.md` | 本文件 |

### 1.2 修改

| 文件 | 变更 |
| --- | --- |
| `src-tauri/src/engine/binaries.rs` | 新增 ffprobe 字段与 `has_ffprobe()`；`looks_bundled`/`is_bundled_app`/`resolve_tool` 统一解析；**发布版不回落 Homebrew/PATH**；抽出 `short_version()` 并从 `ffprobe version …` 横幅中取版本号；新增 2 个单测 |
| `src-tauri/src/manager/mod.rs` | 需要 FFmpeg 的任务在创建时硬拦截：`merge_to_mp4`、`audio_format` 或 selector 含 `+`（分离流）时缺 ffmpeg / ffprobe 直接返回 `EngineMissing`，避免“下载完才发现无法后处理” |
| `src-tauri/src/error.rs` | 新增 `EngineMissing(&'static str)` → 「应用内置的 {0} 不可用，请重新安装 VideoFlow」 |
| `src-tauri/src/commands/system.rs` | 新增 `reveal_licenses` 命令 + `licenses_dir()`（`Resources/LICENSES` → 开发期 `../licenses`） |
| `src-tauri/src/lib.rs` | 注册 `reveal_licenses`；启动日志新增 ffprobe 行 |
| `src-tauri/tauri.conf.json` | `externalBin` 增加 `binaries/ffmpeg`、`binaries/ffprobe`；新增 `resources: {"../licenses": "LICENSES"}` |
| `src/types/index.ts` | `EngineStatus` 增加 `ffprobePath` / `ffprobeVersion` |
| `src/lib/api.ts` | 新增 `revealLicenses()` |
| `src/pages/SettingsPage.tsx` | 引擎状态增加 FFprobe 行；「关于」增加第三方许可证入口；修正“引擎未就绪”文案为发布版语义 |
| `.gitignore` | 忽略 `.build/`（源码与中间产物），并注明 ffmpeg/ffprobe 不入库 |

未改动：下载核心（yt-dlp 参数与进度解析）、任务状态机、SQLite schema、既有测试、React 页面结构。

---

## 2. FFmpeg 构建方案（要点）

| 项 | 值 |
| --- | --- |
| 版本 | FFmpeg 8.0.1（源码 sha256 `05ee0b03…e5a41`） |
| 外部库 | LAME 3.100（LGPL-2.0）、libopus 1.5.2（BSD-3-Clause），均静态链接 |
| 许可证开关 | `--disable-gpl --disable-version3 --disable-nonfree --disable-autodetect` |
| 组件策略 | `--disable-everything` + 白名单（7 协议 / 11 解复用 / 11 复用 / 16 解码 / 5 编码 / 8 解析器 / 5 bsf / 14 滤镜） |
| 产物 | `ffmpeg` 8,359,080 B；`ffprobe` 8,165,896 B；`arm64`，`minos 11.0` |
| 动态依赖 | `libSystem`、`CoreFoundation`、`CoreVideo`、`CoreMedia`、`libz`（无 Homebrew 路径） |
| 为什么加 libopus | FFmpeg 原生 opus 编码器是 experimental（需 `-strict -2`），yt-dlp 不会传该参数，不加 libopus 会导致 opus 格式回退 |
| 复现 | `./scripts/build-ffmpeg-lgpl.sh`（约 1 分钟），产物直接写入 `src-tauri/binaries/` |

### 2.1 许可证审计：7 组独立证据

1. `config.h`：`CONFIG_GPL 0`、`CONFIG_VERSION3 0`、`CONFIG_NONFREE 0`
2. `configure.log` 的 `configuration:` 行不含任何 GPL/version3/nonfree 开关（脚本 `die` 断言）
3. 启用的外部库只有 `CONFIG_LIBMP3LAME`、`CONFIG_LIBOPUS`
4. `ffbuild/config.mak`：`EXTRALIBS=-lm -lz`；`EXTRALIBS-avcodec` 仅多 `-lmp3lame -lopus`
5. GPL-only 目标文件（`x264.o`/`x265.o`/`libvpxenc.o`/`postprocess.o`/`vf_frei0r.o`）不存在
6. 符号表：`x264_*`/`x265_*`/`vpx_*` 为 0；`lame_*` 11 个、`opus_*` 2 个
7. `ffmpeg -L` 自述 LGPL v2.1 or later

### 2.2 LGPL §6 义务落地

| 义务 | 落地 |
| --- | --- |
| 显著声明 + 许可证全文 | `Contents/Resources/LICENSES/`（6 个文件），设置页可一键打开 |
| 完整对应源码 | 版本与 sha256 固定在脚本；发布页提供官方 tarball 与哈希 |
| 可重新链接的目标码 | **589 个 `.o` + 8 个 `.a`**，`.build/ffmpeg-lgpl/objects/`，22 MB；归档 tar.gz sha256 `6392fdc29e24b1347fd043b05c356af83a531e28d5fab74b9126038103e7d963` |
| 书面要约（3 年） | `licenses/SOURCE_OFFER.txt`，含 Issue 索取渠道 |
| 修改声明 | 三库均未修改，仅 configure 裁剪 |

> 本轮修正了一处会破坏义务的缺陷：`KEEP_OBJECTS=1` 原先用扁平 `cp` 收集 `.o`，`libavcodec`/`libavformat`
> 下的同名文件互相覆盖（589 → 553）。改为 `rsync` 保留目录结构后，589 个 `.o` 完整保留。

---

## 3. yt-dlp 决策落地

| 事项 | 本轮做法 |
| --- | --- |
| PyInstaller 打包架构 | 不变（保持 onefile），未重建 Python onedir |
| `com.apple.security.cs.disable-library-validation` | 保留 |
| 文档说明 | 保留原因（onefile 运行时解压异 Team ID 的 `Python.framework` 并 `dlopen`，否则 `exit=255`）与安全影响（削弱库加载校验；`--deep` 使主进程也带上该权限）写入 `docs/NOTARIZATION.md` 第 2 节 |
| 功能保障 | 签名后从 DMG 挂载点以隔离环境实测：`yt-dlp --version` = `2026.10.26`，真实下载合并成功 |
| 未来项目 | onedir 与 entitlement 收敛列为**独立技术评估项目**；明确说明 onedir 在**当前 PyInstaller 架构下更值得评估**，但**不是移除 entitlement 的唯一方案** |

---

## 4. 验证结果

### 4.1 隔离环境启动（`env -i HOME=$HOME PATH=/usr/bin:/bin TMPDIR=/tmp`，从 DMG 挂载点）

```
yt-dlp:  /Volumes/VideoFlow/VideoFlow.app/Contents/MacOS/yt-dlp (2026.10.26)
ffmpeg:  /Volumes/VideoFlow/VideoFlow.app/Contents/MacOS/ffmpeg (8.0.1)
ffprobe: /Volumes/VideoFlow/VideoFlow.app/Contents/MacOS/ffprobe (8.0.1)
```

对比上一轮基线：`ffmpeg: /opt/homebrew/bin/ffmpeg (8.0)` —— 说明发布版已不再依赖开发机 Homebrew。

> 本轮顺带修复了版本号展示缺陷：`probe_version` 只剥离 `ffmpeg version ` 前缀，ffprobe 会把整条版权横幅
> 显示到设置页；已抽出 `short_version()` 同时处理两种横幅，并加单测。

### 4.2 功能验证（全部在隔离环境、使用随包二进制）

| 场景 | 结果 |
| --- | --- |
| `-c copy -movflags +faststart` 重封装 | 26,347,813 B；ffprobe `h264 852x480` + `aac`，`duration=212.31` |
| MP3 / M4A / WAV / AAC / Opus / FLAC | 3,398,027 / 3,519,345 / 40,763,470 / 3,548,286 / 2,467,487 / 45,861,153 B，全部成功 |
| Opus 编解码 | ffprobe `opus,48000`（证明 libopus 生效，无 `-strict -2`） |
| yt-dlp 端到端 | BV1GJ411x7h7 360p → 9.2 MB，ffprobe `av1 640x360` + `aac`（随包 ffmpeg 合并） |
| 引擎缺失硬拦截 | 代码级验证：`merge_to_mp4` / 指定 `audio_format` / selector 含 `+` 时，缺 ffmpeg/ffprobe 直接返回 `EngineMissing`（代码审查 + 单测覆盖解析层，未做强杀二进制的运行期复现） |
| 应用包结构 | `Contents/MacOS/{videoflow,yt-dlp,ffmpeg,ffprobe}` + `Contents/Resources/LICENSES/{6 files}` + `icon.icns`；`SOURCE_OFFER.txt` 与仓库版本逐字节一致（`4655d007…7ea3`） |

### 4.3 签名与分发

| 项 | 结果 |
| --- | --- |
| `codesign --verify --deep --strict` | 通过（DMG 挂载内同样通过） |
| Hardened Runtime | 4 个二进制均 `flags=0x10000(runtime)` |
| Entitlement | 4 个二进制均带 `disable-library-validation`（Tauri `--deep` 扩散） |
| 公证 | **BLOCKED**（无凭据） |
| Gatekeeper | `spctl` → `rejected` / `source=Unnotarized Developer ID`（未公证的必然结果） |
| 票据 | 无（`stapler validate` 报无票据） |

### 4.4 质量门禁（含退出码）

| 命令 | 退出码 | 结果 |
| --- | --- | --- |
| `cargo fmt --all --check` | 0 | 无差异 |
| `cargo clippy --all-targets -- -D warnings` | 0 | 无告警 |
| `cargo test` | 0 | **34 passed** / 0 failed（本轮新增 2 个单测） |
| `pnpm typecheck` | 0 | 无类型错误 |
| `pnpm lint` | 0 | 无 ESLint 报告 |
| `pnpm format:check` | 0 | 全面匹配 Prettier |
| `pnpm build` | 0 | JS 450.27 kB（gzip 144.94 kB） |
| `pnpm tauri build --target aarch64-apple-darwin` | 0 | 生成 .app 66.80 MiB / .dmg 49.46 MiB |

### 4.5 最终产物与哈希

| 产物 | 大小 | SHA-256 |
| --- | --- | --- |
| `VideoFlow_0.1.0_aarch64.dmg` | 49.46 MiB | `b816aa290d905c440446f4bd63fa8d1287647088d247051859bb1f903b5d461d` |
| `VideoFlow.app`（目录） | 66.80 MiB | — |
| `Contents/MacOS/videoflow` | — | `efb8390d8a11f7662f96b9f0a64abb334d55c86b829eb7789a0387fc5a5f8117` |
| `Contents/MacOS/ffmpeg` | 8,359,080 B | `816c1beca5a2b910a94e8dfbd5dcb3108304128c7ca33778362eee9041d6f255` |
| `Contents/MacOS/ffprobe` | 8,165,896 B | `d6862ce8c7b14cc70308fceeea7b0a62e28a776ef46c85decb3e8095ee257f25` |
| `Contents/MacOS/yt-dlp` | 37,466,304 B | `74e0ec00aae77eb31d939a7d52696a650ebd6b994f2aea50c082f95b1126680e` |

路径：`src-tauri/target/aarch64-apple-darwin/release/bundle/{macos/VideoFlow.app,dmg/VideoFlow_0.1.0_aarch64.dmg}`

---

## 5. 未完成 / 风险

| 项 | 状态 | 说明 |
| --- | --- | --- |
| 公证 + 票据装订 | **BLOCKED** | 缺 Apple ID / API Key 凭据；操作模板见 `docs/NOTARIZATION.md` 第 3 节 |
| 设置页「第三方许可证」按钮 | **NOT TESTED** | 截图与日志均未覆盖真实点击；`reveal_licenses` 逻辑已通过编译与代码审查，`Resources/LICENSES` 结构已实测存在 |
| 引擎缺失的运行期拦截 | 部分验证 | 单测覆盖解析与缺省逻辑；未通过删除 sidecar 的签名产物做端到端复现 |
| Intel / universal | 未构建 | 需在 x86_64 下重跑 FFmpeg 脚本并重新取证 |
| Rust/npm 依赖的许可证全文随包 | 未做 | 后续用 `cargo-about` 生成后并入 `LICENSES/` |
| 通知横幅 | 未验证 | 系统对 `app.videoflow.desktop` 的授权当前为 Denied（沿用既有结论） |
| 3 年要约的存档 | 人工步骤 | 每次发布需归档 `.build/ffmpeg-lgpl/objects/` 与源码 tarball |

---

## 6. 复现步骤

```bash
# 1) 取 sidecar 与 FFmpeg
./scripts/fetch-yt-dlp.sh
KEEP_OBJECTS=1 ./scripts/build-ffmpeg-lgpl.sh     # 同时产出再链接材料

# 2) 质量门禁
(cd src-tauri && cargo fmt --all --check && cargo clippy --all-targets -- -D warnings && cargo test)
pnpm typecheck && pnpm lint && pnpm format:check && pnpm build

# 3) 签名构建
APPLE_SIGNING_IDENTITY="Developer ID Application: jianyu chen (HQC33J8U5Y)" \
  pnpm tauri build --target aarch64-apple-darwin

# 4) 验证
codesign --verify --deep --strict --verbose=2 \
  src-tauri/target/aarch64-apple-darwin/release/bundle/macos/VideoFlow.app
hdiutil attach -nobrowse \
  src-tauri/target/aarch64-apple-darwin/release/bundle/dmg/VideoFlow_0.1.0_aarch64.dmg
env -i HOME="$HOME" PATH=/usr/bin:/bin TMPDIR=/tmp \
  /Volumes/VideoFlow/VideoFlow.app/Contents/MacOS/videoflow
```

日志位置：`~/Library/Logs/app.videoflow.desktop/VideoFlow.log`（同时输出到 stdout）。
