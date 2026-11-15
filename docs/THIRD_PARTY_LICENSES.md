# 第三方组件与许可证清单

适用于 VideoFlow 0.1.0（macOS / Apple Silicon）release 产物。本文档记录**随包分发**的全部第三方组件、
各自的许可证，以及 FFmpeg 静态 LGPL 链接所对应的再分发义务如何落地。

> 本文档是工程侧的合规取证记录，**不构成法律意见**。正式商业分发前建议由法务复核第 3、5 节。

相关文件：

| 文件 | 作用 |
| --- | --- |
| `scripts/build-ffmpeg-lgpl.sh` | FFmpeg / LAME / libopus 的可复现静态构建脚本（固定版本 + sha256） |
| `licenses/SOURCE_OFFER.txt` | LGPL v2.1 §6c / GPL v2 §3 书面要约与再链接说明 |
| `licenses/FFmpeg-LGPL-2.1.txt` | LGPL v2.1 全文 |
| `licenses/FFmpeg-LICENSE.md` | FFmpeg 上游许可证说明（含各目录的许可差异） |
| `licenses/LAME-LGPL-2.0.txt` | LAME 的 LGPL v2.0 全文 |
| `licenses/libopus-BSD-3-Clause.txt` | libopus 的 BSD-3-Clause 全文 |
| `licenses/yt-dlp-THIRD_PARTY_LICENSES.txt` | yt-dlp 官方发布归档内自带的第三方清单（原样提取） |

上述文件通过 `bundle.resources` 打进 `VideoFlow.app/Contents/Resources/LICENSES/`，用户可在
「设置 › 关于 › 第三方许可证」直接打开该目录。

---

## 1. 结论摘要

| 结论 | 依据 |
| --- | --- |
| 随包分发的 4 个可执行文件：`videoflow`、`yt-dlp`、`ffmpeg`、`ffprobe` | `Contents/MacOS/` 实测 |
| `ffmpeg` / `ffprobe` 为**自建静态 LGPL 构建**，不含 x264 / x265 / libvpx / frei0r / postproc 等 GPL 组件 | 第 2.4 节逐项取证 |
| 应用主程序（Rust/React）**不静态链接** FFmpeg 与 yt-dlp，仅以子进程方式调用 | `otool -L` 只有系统库；源码中只有 `Command` 调用 |
| GPL / GPLv3 组件未进入 FFmpeg 构建；应用中唯一 GPL 系组件是 yt-dlp 归档内自带的 `mutagen`（GPL-2.0-or-later） | 第 2.4 / 5.3 节 |
| LGPL v2.1 §6 的静态链接义务已具备落地材料：许可证文本、固定源码、589 个 `.o`、8 个 `.a`、构建脚本、3 年书面要约 | 第 3、4 节 |
| 无「无法满足」的阻塞项；`--disable-gpl` 只是必要条件，合规依靠第 2.4 节的多重取证 | — |

---

## 2. FFmpeg：静态 LGPL 构建

### 2.1 决策记录

采用**静态链接的 LGPL 构建**，不采用 `.dylib` + `install_name_tool` 的动态方案。

理由：

- 只多出两个自包含可执行文件（8.0 MB / 7.8 MB），没有 `.dylib`、`@rpath`、`LC_RPATH` 修补，
  也没有额外的嵌套签名对象。
- Tauri 的 `externalBin` 会把 sidecar 直接放进 `Contents/MacOS/` 并逐个签名，静态产物天然适配这条链路。
- 干净 macOS 环境只需系统库（`libSystem` / `CoreFoundation` / `CoreVideo` / `CoreMedia` / `libz`），
  不会出现“换台机器找不到 dylib”。

明确不采用：GPL / GPLv3 构建（哪怕更省事）。若未来需要 x264/x265 等 GPL 组件，必须另行立项并
履行 GPLv2/v3 的完整义务，不能在本方案上打补丁。

### 2.2 构建参数（`scripts/build-ffmpeg-lgpl.sh` 可一键复现）

固定输入：

| 组件 | 版本 | SHA-256 |
| --- | --- | --- |
| FFmpeg | 8.0.1 | `05ee0b03119b45c0bdb4df654b96802e909e0a752f72e4fe3794f487229e5a41` |
| LAME | 3.100 | `ddfe36cab873794038ae2c1210557ad34857a4b6bdc515785d1da9e175b1da1e` |
| libopus | 1.5.2 | `65c1d2f78b9f2fb20082c38cbe47c951ad5839345876e46941612ee87f9a7ce1` |

许可证相关开关：

```
--disable-gpl --disable-version3 --disable-nonfree
--disable-autodetect          # 关闭对 Homebrew / 系统库的自动探测，杜绝误链 GPL 库
--enable-static --disable-shared --enable-pic
--enable-libmp3lame --enable-libopus     # 仅有的两个外部库
--pkg-config-flags=--static --pkg-config=<path to pkg-config>
--extra-libs="-lm -lz"
```

构建链：Apple clang + macOS SDK，`-arch arm64 -mmacosx-version-min=11.0`，
`--target-os=darwin`。脚本内置断言：若 `configure.log` 的 `configuration:` 行出现
`--enable-gpl` / `--enable-version3` / `--enable-nonfree`，构建立即中止。

组件采用**白名单**方式（`--disable-everything` 后逐个 `--enable-*`），只保留 VideoFlow 真实走到的路径：

| 类别 | 启用项 |
| --- | --- |
| 协议 | file, pipe, data, concat, hls, http, https |
| 解复用 | mov, matroska, mp3, wav, aac, flac, ogg, concat, hls, dash, mpegts |
| 复用 | mp4, mov, matroska, webm, mp3, ipod, adts, wav, flac, opus, ogg |
| 解码 | h264, hevc, mpeg4, vp8, vp9, av1, mjpeg, aac, aac_latm, mp3, opus, vorbis, flac, pcm_s16le, pcm_s24le, pcm_f32le |
| 编码 | libmp3lame, libopus, aac, flac, pcm_s16le |
| 解析器 | h264, hevc, aac, mpegaudio, opus, vorbis, vp9, av1 |
| 比特流过滤 | h264_mp4toannexb, hevc_mp4toannexb, aac_adtstoasc, vp9_superframe, setts |
| 滤镜 | aresample, aformat, anull, anullsrc, atrim, asetpts, concat, format, null, scale, trim, setpts, volume, fps |

### 2.3 为什么需要 libmp3lame 与 libopus

- MP3 提取需要编码器。FFmpeg 自带的 `mp3` 编码器不可用（仅解码），`libmp3lame` 是唯一 LGPL 兼容的
  MP3 编码方案。
- Opus 输出：FFmpeg 8.0 的原生 `opus` 编码器标记为 **experimental**，实测必须加 `-strict -2` 才能用；
  yt-dlp 不会加这个参数，因此直接用原生编码器会导致 opus 格式提取失败。改为静态链接 `libopus`
  后 `apex` 正常输出（实测 48 kHz，`codec_name=opus`），与 Homebrew 版行为一致。
- 两个库都不引入 GPL：LAME 为 LGPL-2.0，libopus 为 BSD-3-Clause。

### 2.4 合规取证（不依赖 `--disable-gpl` 单点判断）

判定“确实没有 GPL / GPLv3 组件”依据以下 7 组互相独立的证据：

| # | 取证项 | 实测结果 |
| --- | --- | --- |
| 1 | `config.h` 许可证宏 | `CONFIG_GPL 0`、`CONFIG_VERSION3 0`、`CONFIG_NONFREE 0` |
| 2 | `configure.log` 的 `configuration:` 行 | 不含 `--enable-gpl` / `--enable-version3` / `--enable-nonfree`（脚本已断言） |
| 3 | 启用的外部库数量 | `grep '^#define CONFIG_LIB.* 1$'` 只有 `CONFIG_LIBMP3LAME`、`CONFIG_LIBOPUS` 两项 |
| 4 | 链接行 | `ffbuild/config.mak` 中 `EXTRALIBS=-lm -lz`；`EXTRALIBS-avcodec` 只多 `-lmp3lame -lopus`；`EXTRALIBS-avutil` 只多 Apple 框架 |
| 5 | GPL-only 目标文件 | `x264.o` / `x265.o` / `libvpxenc.o` / `postprocess.o` / `vf_frei0r.o` 均不存在 |
| 6 | 符号表 | `x264_*` / `x265_*` / `vpx_*` 符号 0 个；`lame_*` 11 个；`opus_*` 2 个 |
| 7 | 运行时自述 | `ffmpeg -L` 输出 “GNU Lesser General Public License ... version 2.1 or later” |

动态依赖（`otool -L`）：

```
/usr/lib/libSystem.B.dylib
/System/Library/Frameworks/CoreFoundation.framework/Versions/A/CoreFoundation
/System/Library/Frameworks/CoreVideo.framework/Versions/A/CoreVideo
/System/Library/Frameworks/CoreMedia.framework/Versions/A/CoreMedia
/usr/lib/libz.1.dylib
```

没有指向 `/opt/homebrew`、`/usr/local` 或任何自建目录的依赖项。

### 2.5 功能对等性验证

以真实 480p 素材（852×480, h264+aac, 212.3 s）在**隔离环境**（`env -i`，`PATH=/usr/bin:/bin`，
不暴露 Homebrew）中使用随包二进制执行：

| 操作 | 结果 |
| --- | --- |
| `-c copy -movflags +faststart` 重封装 | 26,347,813 B；ffprobe `h264 852x480` + `aac`，`duration=212.31` |
| MP3 | 3,398,027 B（libmp3lame） |
| M4A | 3,519,345 B（aac + ipod muxer） |
| WAV | 40,763,470 B |
| AAC（ADTS） | 3,548,286 B |
| Opus | 2,467,487 B，ffprobe `opus,48000`（libopus） |
| FLAC | 45,861,153 B |
| 端到端（yt-dlp 合并） | 随包 yt-dlp + `--ffmpeg-location Contents/MacOS`，BV1GJ411x7h7 360p → 9.2 MB，ffprobe `av1 640x360` + `aac` |

---

## 3. LGPL v2.1 义务逐条落地

FFmpeg 与 LAME 均按 **LGPL v2.1 or later**（LAME 上游为 LGPL-2.0）分发，且 VideoFlow 的 FFmpeg
是**静态链接**的，因此触发 §6 的“组合作品”义务。

| LGPL v2.1 义务 | 条款 | 落地方式 | 证据 |
| --- | --- | --- | --- |
| 显著声明使用了该库、并说明适用 LGPL | §6 前言 / §1 | 应用内「设置 › 关于 › 第三方许可证」可直接打开 `Contents/Resources/LICENSES/`，其中含 `FFmpeg-LICENSE.md`、`LAME-LGPL-2.0.txt` | 目录实测 |
| 附带许可证全文 | §1、§6 | `FFmpeg-LGPL-2.1.txt`、`LAME-LGPL-2.0.txt`、`libopus-BSD-3-Clause.txt` 随包 | 同上 |
| 提供库的完整对应源码（含修改） | §6a | 源码版本与哈希固定在构建脚本；发布页提供源码压缩包与 `ffmpeg-8.0.1.tar.xz` / `lame-3.100.tar.gz` / `opus-1.5.2.tar.gz` 的官方下载地址与校验值 | `SOURCE_OFFER.txt` |
| 提供“使用该库的作品”的目标码，使第三方可改库后重新链接 | §6a | 保留 **589 个 `.o`** + **8 个 `.a`**（libavcodec/libavformat/libavutil/libavfilter/libswscale/libswresample/libmp3lame/libopus） | `KEEP_OBJECTS=1 ./scripts/build-ffmpeg-lgpl.sh`，产物 `.build/ffmpeg-lgpl/objects/`（22 MB） |
| 或改为“书面要约”形式提供上述材料 | §6c | 3 年有效书面要约，按第 4 节流程交付 | `licenses/SOURCE_OFFER.txt` |
| 声明是否修改过库 | §6a | **未修改**。三个库均以上游 tarball 原样解压构建，仅通过 configure 参数裁剪 | 构建脚本只做 `cp -R` + configure，无 patch |
| 允许反向工程以调试修改后的库 | §6 | 未添加任何禁止条款；`com.apple.security.cs.disable-library-validation` 与“禁止调试”无关，见 `NOTARIZATION.md` | — |
| 不得使用作者名义背书 | §6 | 应用内与文档中不作“FFmpeg 官方认证”类表述 | — |

补充说明：

1. 上述材料中真正“不可替代”的是 **`.o` 目标码**。只给源码不给目标码，第三方无法在修改 FFmpeg 后
   重新链接出自己的 `ffmpeg` 可执行文件（VideoFlow 分发的是可执行文件而不是库）。
2. 因此构建脚本在 `KEEP_OBJECTS=1` 时用 **保留目录结构**的方式收集 `.o`（`libavcodec/`、`libavformat/`
   等目录下有大量同名文件，早期扁平复制会互相覆盖，导致 589 个只剩 553 个）。这一点已在脚本中修正。
3. 再链接不涉及 VideoFlow 主程序：VideoFlow 与 FFmpeg 是进程间调用关系，用户替换 `Contents/MacOS/ffmpeg`
   后重新签名即可，无需重建 Rust 二进制（步骤见第 4 节）。

---

## 4. 再链接材料与操作步骤

**本地生成材料**

```bash
KEEP_OBJECTS=1 ./scripts/build-ffmpeg-lgpl.sh
# 产物：
#   src-tauri/binaries/ffmpeg-aarch64-apple-darwin
#   src-tauri/binaries/ffprobe-aarch64-apple-darwin
#   .build/ffmpeg-lgpl/objects/ffmpeg/**/*.o        （589 个）
#   .build/ffmpeg-lgpl/objects/{libav*,libsw*,libmp3lame,libopus}.a  （8 个）
```

**修改库后重新链接（示意）**

```bash
# 1) 修改并重建库，得到新的 libmp3lame.a / libopus.a / libav*.a
# 2) 用新的库替换 .build/ffmpeg-lgpl/objects/ 中对应的 .a
# 3) 复用 ffmpeg 的链接命令（ffbuild/config.mak 中的 EXTRALIBS 已给出依赖顺序）
cd .build/ffmpeg-lgpl/ffmpeg-src && make ffmpeg   # 或 make ffprobe
```

**把用户自建的 ffmpeg 放进已安装的应用**

```bash
cp <自建>/ffmpeg  /Applications/VideoFlow.app/Contents/MacOS/ffmpeg
codesign --force --options runtime --timestamp --sign "Developer ID Application: <name> (TEAMID)" \
  /Applications/VideoFlow.app/Contents/MacOS/ffmpeg
codesign --force --options runtime --timestamp --sign "Developer ID Application: <name> (TEAMID)" \
  /Applications/VideoFlow.app
```

VideoFlow 只按路径调用 `Contents/MacOS/ffmpeg`，因此替换后可立即生效；设置页会显示新的版本号。

**源码交付**：按 `licenses/SOURCE_OFFER.txt` 中的地址与哈希提供，或提交 GitHub Issue
`Source Request: <组件名>` 索取；承诺期 3 年。

---

## 5. yt-dlp（PyInstaller onefile）

### 5.1 处置原则

- 随包分发**未修改**的上游 `yt-dlp` 可执行文件（版本 `2026.10.26`），以子进程方式调用。
- 不把 yt-dlp / CPython 静态链接进 VideoFlow，避免许可证与运行时耦合。
- 归档内组件清单以 `pyi-archive_viewer -l -r` 精确导出（共 1727 条目），上游自带的
  `THIRD_PARTY_LICENSES.txt`（243,550 B）原样随包。

### 5.2 内嵌组件与许可证

| 组件 | 版本/形态 | 许可证 | 备注 |
| --- | --- | --- | --- |
| yt-dlp 本体 | 2026.10.26 | Unlicense | 公共领域 |
| CPython | 3.14（`Python.framework`） | PSF-2.0 | 运行时解压到临时目录 |
| PyInstaller bootloader | 6.x | GPL-2.0-or-later **附打包例外** | 例外条款允许打包分发，不要求被包装程序开源 |
| mutagen | 1.48.1 | **GPL-2.0-or-later** | 元数据写入；见 5.3 |
| Cryptodome | 3.24.1 | Public Domain + BSD-2-Clause | |
| OpenSSL | 3.x（`_ssl.so` → `@rpath/libssl.3.dylib`） | Apache-2.0 | 上游 3.0 起为 Apache-2.0 |
| SQLite | 3.50.x（`_sqlite3.so` 静态内嵌） | Public Domain | |
| zlib / libzstd | 系统 zlib / `libzstd.1.dylib` | Zlib / BSD-3-Clause | |
| readline 扩展 | `readline.cpython-314-darwin.so` → `/usr/lib/libedit.3.dylib` | BSD-3-Clause（libedit） | 见 5.4 |
| certifi | 2026.10.23 | MPL-2.0 | 仅分发未修改文件，无源码义务 |
| requests / urllib3 / idna / brotli / websockets / curl_cffi / cffi / pycparser | 见上游清单 | Apache-2.0 / MIT / BSD | 宽松许可 |

### 5.3 mutagen 为 GPL-2.0-or-later 的处置

yt-dlp 上游把 mutagen 打进 onefile 归档，因此**该可执行文件的整体分发应按 GPLv2 对待**。处置方式：

1. 分发**未修改**的上游产物，不额外修改或重打包其中的 Python 模块；
2. 通过 `licenses/yt-dlp-THIRD_PARTY_LICENSES.txt` 与 `SOURCE_OFFER.txt` 披露，并提供 mutagen 与
   yt-dlp 的源码获取途径（上游 sdist / 官方仓库 commit）；
3. mutagen 与 VideoFlow 之间是**进程边界**：VideoFlow 只 `exec` yt-dlp 并读取它的 stdout / 文件产物，
   不 `dlopen`、不链接、不共享地址空间，因此不构成 GPL 意义上的组合作品，不会“传染”Rust/React 代码。

### 5.4 「readline 是 GNU Readline（GPL-3）」的排除

上游 `THIRD_PARTY_LICENSES.txt` 汇总了 Linux 构建下的依赖，会让人误以为归档里含 GNU Readline。
本轮直接对归档内的扩展做 `otool -L`：

```
python3.14/lib-dynload/readline.cpython-314-darwin.so
  → /usr/lib/libedit.3.dylib        # BSD-3-Clause，macOS 系统库
```

即 macOS 版 Python 的 `readline` 模块链接的是 **libedit**，不是 GNU Readline，归档内也不存在
`libreadline*.dylib`。此项**不构成** GPL-3 义务。

### 5.5 PyInstaller bootloader 的例外

bootloader 本身是 GPL-2.0-or-later，但带有官方例外：允许将 bootloader 与任意程序打包后按任意条款
分发（“You may use PyInstaller to package your own programs without affecting their licensing”）。
因此分发 yt-dlp 的 onefile 产物不需要开源 VideoFlow。若未来改为自建 onedir 构建，这条结论不变。

---

## 6. Rust / npm 依赖

| 范围 | 数量 | 许可证分布 |
| --- | --- | --- |
| Rust crates | 493 | MIT OR Apache-2.0 211、MIT 128、Apache-2.0 OR MIT 53、Unicode-3.0 18、Zlib 组合 17、Zlib OR Apache-2.0 OR MIT 2、Unlicense OR MIT 9、MPL-2.0 7、BSD-3-Clause 2、其他宽松许可若干（含 `r-efi` 三重许可项，其中一项为 LGPL-2.1-or-later，实际选择 MIT/Apache 分支） |
| npm 生产依赖 | 60 | MIT 53、MIT OR Apache-2.0 3、Apache-2.0 1、Apache-2.0 OR MIT 1、ISC 1、0BSD 1 |

义务与处置：

- **MIT / BSD / ISC / 0BSD / Unlicense**：需保留版权与许可声明。当前版本未在应用内展示这部分文本，
  计划在后续版本内附 `cargo-about` 生成的汇总文件（命令见第 7 节）。
- **Apache-2.0**（Tauri、OpenSSL 等）：需保留 LICENSE 与 NOTICE。Tauri 的 `LICENSE` 随 crate 分发，
  不修改上游文件即满足。
- **MPL-2.0**（`cssparser` 0.37/0.38、`cssparser-macros`、`selectors` 0.38/0.41、`dtoa-short`、`option-ext`）：
  以文件为单位传染，**未修改**上游文件，因此无源码公开义务。
- **Unicode-3.0**（18 个 crates）：需在文档中署名 Unicode 联盟，见 `licenses/SOURCE_OFFER.txt`。
- **`r-efi`**：三选一许可（Apache-2.0 / MIT / LGPL-2.1-or-later），在 Rust 依赖解析中实际选择宽松分支。

---

## 7. 未决事项

| 项 | 状态 | 处理建议 |
| --- | --- | --- |
| Rust / npm 依赖的完整许可证文本随包 | 未做 | `cargo install cargo-about && cargo about generate about.hbs -o licenses/RUST-3RD-PARTY.html`；再对 `pnpm list --prod` 结果合并 |
| 正式法律审查 | 未做 | 商业分发前由法务复核第 3、5 节 |
| `.o` / 源码归档的发布位置 | 人工步骤 | 每次发布把 `.build/ffmpeg-lgpl/objects/` 与源码 tarball 归档到发布附件，并按 `SOURCE_OFFER.txt` 保留 3 年 |
| Intel / universal 构建 | 未构建 | 若需支持 x86_64，需要在 Intel 或 `-arch x86_64` 下重跑脚本并重新取证 |
| 商标 | 未处理 | 不得暗示 FFmpeg / yt-dlp 项目为 VideoFlow 背书；如需使用其 logo 需另行确认 |
