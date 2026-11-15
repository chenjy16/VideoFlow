#!/usr/bin/env bash
#
# 构建随应用分发的 FFmpeg / FFprobe（静态链接 + LGPL 精简构建）
#
# 设计目标：
#   1. 只链接 LGPL 组件（--disable-gpl --disable-version3 --disable-nonfree）
#   2. 不依赖目标机器上的任何动态库（静态链接，仅系统库）
#   3. 关闭 autodetect，避免意外把开发机 Homebrew 的 GPL 库（x264/x265 等）链进来
#   4. 只保留 VideoFlow / yt-dlp 实际需要的解复用器、复用器、编解码器、滤镜
#
# 产物：
#   src-tauri/binaries/ffmpeg-aarch64-apple-darwin
#   src-tauri/binaries/ffprobe-aarch64-apple-darwin
#
# 除 FFmpeg 自身外，只静态链接两个许可兼容（LGPL / BSD）的第三方库：
#   - LAME 3.100（LGPL-2.0）      → libmp3lame，MP3 输出
#   - libopus 1.5.2（BSD-3-Clause）→ 无 GPL 风险的 opus 编码，保持与旧版 Homebrew 构建的功能对等
#
# 用法：
#   ./scripts/build-ffmpeg-lgpl.sh              # 构建并安装到 src-tauri/binaries/
#   KEEP_OBJECTS=1 ./scripts/build-ffmpeg-lgpl.sh   # 额外保留 .o 目标文件（LGPL 再链接材料）
#
# 许可证义务：见 docs/THIRD_PARTY_LICENSES.md 与 licenses/SOURCE_OFFER.txt
#
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FFMPEG_VERSION="${FFMPEG_VERSION:-8.0.1}"
FFMPEG_SHA256="${FFMPEG_SHA256:-05ee0b03119b45c0bdb4df654b96802e909e0a752f72e4fe3794f487229e5a41}"
LAME_VERSION="${LAME_VERSION:-3.100}"
LAME_SHA256="${LAME_SHA256:-ddfe36cab873794038ae2c1210557ad34857a4b6bdc515785d1da9e175b1da1e}"
OPUS_VERSION="${OPUS_VERSION:-1.5.2}"
OPUS_SHA256="${OPUS_SHA256:-65c1d2f78b9f2fb20082c38cbe47c951ad5839345876e46941612ee87f9a7ce1}"

MACOS_MIN="${MACOS_MIN:-11.0}"
TARGET_ARCH="${TARGET_ARCH:-arm64}"
TARGET_TRIPLE="${TARGET_TRIPLE:-aarch64-apple-darwin}"
JOBS="${JOBS:-$(sysctl -n hw.ncpu)}"

BUILD_ROOT="${REPO_ROOT}/.build/ffmpeg-lgpl"
PREFIX="${BUILD_ROOT}/prefix"
LAME_PREFIX="${BUILD_ROOT}/lame"
OPUS_PREFIX="${BUILD_ROOT}/opus"
SRC="${REPO_ROOT}/.build/src"
OUT_DIR="${REPO_ROOT}/src-tauri/binaries"

die() { echo "错误: $*" >&2; exit 1; }
step() { echo; echo "==> $*"; }

# ---------------------------------------------------------------------------
# 0. 工具链检查
# ---------------------------------------------------------------------------
step "检查构建工具链"
for tool in clang make pkg-config curl tar shasum; do
  command -v "$tool" >/dev/null 2>&1 || die "缺少构建工具: $tool"
done
command -v xcrun >/dev/null 2>&1 || die "缺少 xcrun（需要 Xcode Command Line Tools）"
SDKROOT="$(xcrun --sdk macosx --show-sdk-path)"
PKG_CONFIG_BIN="$(command -v pkg-config)"
echo "SDK: ${SDKROOT}"
echo "pkg-config: ${PKG_CONFIG_BIN}"
echo "Clang: $(clang --version | head -1)"

mkdir -p "$SRC" "$PREFIX" "$OUT_DIR"

# ---------------------------------------------------------------------------
# 1. 下载源码（固定版本 + SHA256 校验）
# ---------------------------------------------------------------------------
fetch() {
  local url="$1" dest="$2" want="$3"
  if [ -f "$dest" ] && [ "$(shasum -a 256 "$dest" | cut -d' ' -f1)" = "$want" ]; then
    echo "已存在且校验通过: $(basename "$dest")"
    return 0
  fi
  echo "下载: $url"
  curl -fsSL --retry 3 --retry-delay 2 -o "$dest.part" "$url" || die "下载失败: $url"
  local got
  got="$(shasum -a 256 "$dest.part" | cut -d' ' -f1)"
  [ "$got" = "$want" ] || die "SHA256 不匹配: $(basename "$dest") 期望 $want 实际 $got"
  mv "$dest.part" "$dest"
}

step "获取源代码"
fetch "https://ffmpeg.org/releases/ffmpeg-${FFMPEG_VERSION}.tar.xz" \
      "${SRC}/ffmpeg-${FFMPEG_VERSION}.tar.xz" "$FFMPEG_SHA256"
fetch "https://downloads.sourceforge.net/project/lame/lame/${LAME_VERSION}/lame-${LAME_VERSION}.tar.gz" \
      "${SRC}/lame-${LAME_VERSION}.tar.gz" "$LAME_SHA256"
fetch "https://downloads.xiph.org/releases/opus/opus-${OPUS_VERSION}.tar.gz" \
      "${SRC}/opus-${OPUS_VERSION}.tar.gz" "$OPUS_SHA256"

[ -d "${SRC}/ffmpeg-${FFMPEG_VERSION}" ] || tar xf "${SRC}/ffmpeg-${FFMPEG_VERSION}.tar.xz" -C "$SRC"
[ -d "${SRC}/lame-${LAME_VERSION}" ] || tar xf "${SRC}/lame-${LAME_VERSION}.tar.gz" -C "$SRC"
[ -d "${SRC}/opus-${OPUS_VERSION}" ] || tar xf "${SRC}/opus-${OPUS_VERSION}.tar.gz" -C "$SRC"

# ---------------------------------------------------------------------------
# 2. 构建 LAME（LGPL-2.0+，仅静态库；FFmpeg 需要 libmp3lame 做 MP3 输出）
# ---------------------------------------------------------------------------
step "构建 LAME ${LAME_VERSION}（静态库，不构建命令行前端）"
rm -rf "${BUILD_ROOT}/lame-build"
cp -R "${SRC}/lame-${LAME_VERSION}" "${BUILD_ROOT}/lame-build"
pushd "${BUILD_ROOT}/lame-build" >/dev/null
CFLAGS="-O2 -arch ${TARGET_ARCH} -mmacosx-version-min=${MACOS_MIN} -fPIC" \
LDFLAGS="-arch ${TARGET_ARCH} -mmacosx-version-min=${MACOS_MIN}" \
./configure \
  --prefix="$LAME_PREFIX" \
  --disable-shared \
  --enable-static \
  --disable-frontend \
  --disable-gtktest \
  --disable-decoder >/dev/null
make -j"$JOBS" >/dev/null
make install >/dev/null
popd >/dev/null
[ -f "${LAME_PREFIX}/lib/libmp3lame.a" ] || die "libmp3lame.a 未生成"
echo "libmp3lame.a: $(ls -lh "${LAME_PREFIX}/lib/libmp3lame.a" | awk '{print $5}')"

# ---------------------------------------------------------------------------
# 2b. 构建 libopus（BSD-3-Clause，仅静态库；保持 opus 音频输出能力）
# ---------------------------------------------------------------------------
step "构建 libopus ${OPUS_VERSION}（静态库）"
rm -rf "${BUILD_ROOT}/opus-build"
cp -R "${SRC}/opus-${OPUS_VERSION}" "${BUILD_ROOT}/opus-build"
pushd "${BUILD_ROOT}/opus-build" >/dev/null
CFLAGS="-O2 -arch ${TARGET_ARCH} -mmacosx-version-min=${MACOS_MIN} -fPIC" \
LDFLAGS="-arch ${TARGET_ARCH} -mmacosx-version-min=${MACOS_MIN}" \
./configure \
  --prefix="$OPUS_PREFIX" \
  --disable-shared \
  --enable-static \
  --disable-doc \
  --disable-extra-programs >/dev/null
make -j"$JOBS" >/dev/null
make install >/dev/null
popd >/dev/null
[ -f "${OPUS_PREFIX}/lib/libopus.a" ] || die "libopus.a 未生成"
echo "libopus.a: $(ls -lh "${OPUS_PREFIX}/lib/libopus.a" | awk '{print $5}')"

# ---------------------------------------------------------------------------
# 3. 配置 FFmpeg（精简白名单，全部为 LGPL）
# ---------------------------------------------------------------------------
step "配置 FFmpeg ${FFMPEG_VERSION}（LGPL 精简构建）"
rm -rf "${BUILD_ROOT}/x86out" 2>/dev/null || true
cp -R "${SRC}/ffmpeg-${FFMPEG_VERSION}" "${BUILD_ROOT}/ffmpeg-src.tmp"
rm -rf "${BUILD_ROOT}/ffmpeg-src"
mv "${BUILD_ROOT}/ffmpeg-src.tmp" "${BUILD_ROOT}/ffmpeg-src"

# VideoFlow / yt-dlp 实际会走到的路径：
#   - 合并：mp4/mov/mkv 解复用 + 复用，h264/hevc/aac 流复制（-c copy）
#   - 音频提取：mp3（libmp3lame）、m4a（aac）、flac、wav、opus
#   - 探测：ffprobe 读取上述容器的元数据与码流信息
#   - HLS/DASH 下载后的拼接：concat 解复用器 + 常用 hls/dash 输入
CFG_FLAGS=(
  --prefix="$PREFIX"
  --arch="$TARGET_ARCH"
  --target-os=darwin
  --cc=clang
  --enable-static
  --disable-shared
  --enable-pic
  --disable-avdevice
  # ---- 许可证开关：只允许 LGPL ----
  --disable-gpl
  --disable-version3
  --disable-nonfree
  # ---- 关闭所有外部库自动探测，避免误链 Homebrew 的 GPL 库 ----
  --disable-autodetect
  # ---- 先关掉全部组件，再按白名单逐个开启（否则会编译进大量用不到的代码）----
  --disable-everything
  --disable-doc
  --disable-debug
  --disable-ffplay
  --enable-ffmpeg
  --enable-ffprobe
  --enable-swresample
  --enable-swscale
  --enable-avfilter
  --enable-network
  # ---- 协议 ----
  --enable-protocol=file
  --enable-protocol=pipe
  --enable-protocol=data
  --enable-protocol=concat
  --enable-protocol=hls
  --enable-protocol=http
  --enable-protocol=https
  # ---- 解复用器 ----
  --enable-demuxer=mov
  --enable-demuxer=matroska
  --enable-demuxer=mp3
  --enable-demuxer=wav
  --enable-demuxer=aac
  --enable-demuxer=flac
  --enable-demuxer=ogg
  --enable-demuxer=concat
  --enable-demuxer=hls
  --enable-demuxer=dash
  --enable-demuxer=mpegts
  # ---- 复用器 ----
  --enable-muxer=mp4
  --enable-muxer=mov
  --enable-muxer=matroska
  --enable-muxer=webm
  --enable-muxer=mp3
  --enable-muxer=ipod
  --enable-muxer=adts
  --enable-muxer=wav
  --enable-muxer=flac
  --enable-muxer=opus
  --enable-muxer=ogg
  # ---- 解码器（ffprobe / 少量转码需要） ----
  --enable-decoder=h264
  --enable-decoder=hevc
  --enable-decoder=mpeg4
  --enable-decoder=vp8
  --enable-decoder=vp9
  --enable-decoder=av1
  --enable-decoder=mjpeg
  --enable-decoder=aac
  --enable-decoder=aac_latm
  --enable-decoder=mp3
  --enable-decoder=opus
  --enable-decoder=vorbis
  --enable-decoder=flac
  --enable-decoder=pcm_s16le
  --enable-decoder=pcm_s24le
  --enable-decoder=pcm_f32le
  # ---- 编码器（MP3 / 无损音频输出） ----
  --enable-encoder=libmp3lame
  --enable-encoder=libopus
  --enable-encoder=aac
  --enable-encoder=flac
  --enable-encoder=pcm_s16le
  # ---- 码流解析器 ----
  --enable-parser=h264
  --enable-parser=hevc
  --enable-parser=aac
  --enable-parser=mpegaudio
  --enable-parser=opus
  --enable-parser=vorbis
  --enable-parser=vp9
  --enable-parser=av1
  # ---- 比特流过滤器（容器转换时必需） ----
  --enable-bsf=h264_mp4toannexb
  --enable-bsf=hevc_mp4toannexb
  --enable-bsf=aac_adtstoasc
  --enable-bsf=vp9_superframe
  --enable-bsf=setts
  # ---- 滤镜（yt-dlp 后处理会用到的有限集合） ----
  --enable-filter=aresample
  --enable-filter=aformat
  --enable-filter=anull
  --enable-filter=anullsrc
  --enable-filter=atrim
  --enable-filter=asetpts
  --enable-filter=concat
  --enable-filter=format
  --enable-filter=null
  --enable-filter=scale
  --enable-filter=trim
  --enable-filter=setpts
  --enable-filter=volume
  --enable-filter=fps
  # ---- 仅有的两个外部库（LAME LGPL-2.0+ / libopus BSD-3-Clause，均静态链接） ----
  --enable-libmp3lame
  --enable-libopus
  --pkg-config-flags=--static
  --pkg-config="${PKG_CONFIG_BIN}"
)

EXTRA_CFLAGS="-O2 -arch ${TARGET_ARCH} -mmacosx-version-min=${MACOS_MIN}"
EXTRA_LDFLAGS="-arch ${TARGET_ARCH} -mmacosx-version-min=${MACOS_MIN} -L${LAME_PREFIX}/lib -L${OPUS_PREFIX}/lib"
EXTRA_LIBS="-lm -lz"
CFG_FLAGS+=(
  --extra-cflags="${EXTRA_CFLAGS} -I${LAME_PREFIX}/include -I${OPUS_PREFIX}/include -isysroot ${SDKROOT}"
  --extra-ldflags="${EXTRA_LDFLAGS} -isysroot ${SDKROOT}"
  --extra-libs="${EXTRA_LIBS}"
)

pushd "${BUILD_ROOT}/ffmpeg-src" >/dev/null
# libopus 只能通过 pkg-config 被识别，指向本次自建的静态库
PKG_CONFIG_PATH="${OPUS_PREFIX}/lib/pkgconfig:${LAME_PREFIX}/lib/pkgconfig" \
./configure "${CFG_FLAGS[@]}" > "${BUILD_ROOT}/configure.log" 2>&1 \
  || { tail -40 "${BUILD_ROOT}/configure.log"; die "configure 失败，日志: ${BUILD_ROOT}/configure.log"; }
echo "configure 完成"

# 校验：配置行里不得出现任何 GPL / version3 / nonfree 的有效开关
if grep -E '^configuration:.*--enable-(gpl|version3|nonfree)' "${BUILD_ROOT}/configure.log"; then
  die "检测到 GPL / version3 / nonfree 开关，构建中止"
fi
echo "许可证开关校验通过（无 --enable-gpl / --enable-version3 / --enable-nonfree）"

step "编译 FFmpeg（-j${JOBS}）"
make -j"$JOBS" > "${BUILD_ROOT}/make.log" 2>&1 \
  || { tail -40 "${BUILD_ROOT}/make.log"; die "make 失败，日志: ${BUILD_ROOT}/make.log"; }
popd >/dev/null

# ---------------------------------------------------------------------------
# 4. 安装并放置到 src-tauri/binaries/
# ---------------------------------------------------------------------------
step "安装产物"
rm -rf "$PREFIX"
(cd "${BUILD_ROOT}/ffmpeg-src" && make install >/dev/null)
install -m 755 "${PREFIX}/bin/ffmpeg"  "${OUT_DIR}/ffmpeg-${TARGET_TRIPLE}"
install -m 755 "${PREFIX}/bin/ffprobe" "${OUT_DIR}/ffprobe-${TARGET_TRIPLE}"

if [ "${KEEP_OBJECTS:-0}" = "1" ]; then
  OBJ_DIR="${BUILD_ROOT}/objects"
  rm -rf "$OBJ_DIR"
  mkdir -p "$OBJ_DIR"
  # 必须保留目录结构：libavcodec / libavformat 等目录下有大量同名 *.o，
  # 扁平复制会互相覆盖，导致再链接材料不完整。
  rsync -a \
    --include='*/' --include='*.o' --include='*.a' --exclude='*' \
    "${BUILD_ROOT}/ffmpeg-src/" "${OBJ_DIR}/ffmpeg/"
  cp "${LAME_PREFIX}/lib/libmp3lame.a" "$OBJ_DIR"/ 2>/dev/null || true
  cp "${OPUS_PREFIX}/lib/libopus.a" "$OBJ_DIR"/ 2>/dev/null || true
  # 注意：变量名后面不能直接跟全角括号，bash 会把多字节字符算进变量名
  echo "已保留目标文件到: ${OBJ_DIR}"
  echo "  目标文件数量: $(find "$OBJ_DIR" -name '*.o' | wc -l | tr -d ' ') 个 .o"
fi

# ---------------------------------------------------------------------------
# 5. 产物自检
# ---------------------------------------------------------------------------
step "产物自检"
FFMPEG_BIN="${OUT_DIR}/ffmpeg-${TARGET_TRIPLE}"
FFPROBE_BIN="${OUT_DIR}/ffprobe-${TARGET_TRIPLE}"

echo "--- 版本 ---"
"$FFMPEG_BIN" -hide_banner -version | head -2
"$FFPROBE_BIN" -hide_banner -version | head -1

echo "--- 许可证声明（第 3 行版权后的 License 行） ---"
"$FFMPEG_BIN" -hide_banner -L 2>/dev/null | head -5 || true

echo "--- 动态依赖（应只有系统库） ---"
otool -L "$FFMPEG_BIN"  | tail -n +2 | awk '{print "  ffmpeg  -> "$1}'
otool -L "$FFPROBE_BIN" | tail -n +2 | awk '{print "  ffprobe -> "$1}'

echo "--- 体积 ---"
ls -lh "$FFMPEG_BIN" "$FFPROBE_BIN" | awk '{print "  "$9" "$5}'

echo "--- 架构 ---"
lipo -archs "$FFMPEG_BIN"

echo
echo "构建完成。注意：本脚本只负责产出二进制，许可证清单需同步更新（docs/THIRD_PARTY_LICENSES.md）。"
