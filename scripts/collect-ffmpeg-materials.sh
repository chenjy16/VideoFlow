#!/usr/bin/env bash
# 收集 FFmpeg LGPL 构建的许可证与再链接材料，供缓存、审计与随包分发使用。
#
# 前提：先以 KEEP_OBJECTS=1 跑过 scripts/build-ffmpeg-lgpl.sh。
#
# 产出目录（默认 .build/ffmpeg-lgpl-materials）：
#   sources/     三个源码包 + SHA256SUMS        —— LGPL §6 源码可得性
#   objects/     objects.tar.gz（.o + .a）      —— LGPL §6 可重新链接材料
#   ffmpeg/      config.h / configure.log / make.log —— 无 GPL 的源码级证据
#   licenses/    上游 COPYING + 仓库许可证文本与书面要约
#   BINARIES.sha256  二进制指纹（校验材料与二进制同源）
#   build-info.txt   人可读构建记录
#   BUILD_RECORD.json 机器可读构建记录
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_ROOT="${BUILD_ROOT:-${REPO_ROOT}/.build/ffmpeg-lgpl}"
SRC="${SRC:-${REPO_ROOT}/.build/src}"
OUT="${MATERIALS_DIR:-${REPO_ROOT}/.build/ffmpeg-lgpl-materials}"
BIN_DIR="${BIN_DIR:-${REPO_ROOT}/src-tauri/binaries}"

FFMPEG_VERSION="${FFMPEG_VERSION:-8.0.1}"
LAME_VERSION="${LAME_VERSION:-3.100}"
OPUS_VERSION="${OPUS_VERSION:-1.5.2}"
TRIPLE="${TRIPLE:-aarch64-apple-darwin}"

die() { echo "错误: $*" >&2; exit 1; }

FFMPEG_SRC="${BUILD_ROOT}/ffmpeg-src"
OBJ_DIR="${BUILD_ROOT}/objects"
FFMPEG_BIN="${BIN_DIR}/ffmpeg-${TRIPLE}"
FFPROBE_BIN="${BIN_DIR}/ffprobe-${TRIPLE}"

[ -d "$FFMPEG_SRC" ] || die "缺少 FFmpeg 构建目录: $FFMPEG_SRC（先跑 build-ffmpeg-lgpl.sh）"
[ -d "$OBJ_DIR" ] || die "缺少目标文件目录: $OBJ_DIR（需 KEEP_OBJECTS=1 构建）"
[ -x "$FFMPEG_BIN" ] || die "缺少产物: $FFMPEG_BIN"
[ -x "$FFPROBE_BIN" ] || die "缺少产物: $FFPROBE_BIN"

echo "==> 收集构建材料到 ${OUT}"
rm -rf "$OUT"
mkdir -p "${OUT}/sources" "${OUT}/objects" "${OUT}/ffmpeg" "${OUT}/licenses"

# ---------------------------------------------------------------------------
# 1. 源码包（LGPL §6a/§6b：附带可构建的对应源码）
# ---------------------------------------------------------------------------
for f in "ffmpeg-${FFMPEG_VERSION}.tar.xz" "lame-${LAME_VERSION}.tar.gz" "opus-${OPUS_VERSION}.tar.gz"; do
  [ -f "${SRC}/${f}" ] || die "缺少源码包: ${SRC}/${f}"
  cp "${SRC}/${f}" "${OUT}/sources/"
done
(cd "${OUT}/sources" && shasum -a 256 ./* > SHA256SUMS)
echo "源码包: $(ls -1 "${OUT}/sources" | wc -l | tr -d ' ') 个文件"

# ---------------------------------------------------------------------------
# 2. 再链接材料（LGPL §6：目标文件 + 静态库，必须保留目录结构）
# ---------------------------------------------------------------------------
tar czf "${OUT}/objects/objects.tar.gz" -C "$OBJ_DIR" .
o_count="$(tar tzf "${OUT}/objects/objects.tar.gz" | grep -c '\.o$' || true)"
a_count="$(tar tzf "${OUT}/objects/objects.tar.gz" | grep -c '\.a$' || true)"
[ "${o_count:-0}" -gt 0 ] || die "objects.tar.gz 里没有目标文件"
echo "再链接材料: ${o_count} 个 .o / ${a_count} 个 .a"

# ---------------------------------------------------------------------------
# 3. 构建证据（config.h 三开关 + 完整日志）
# ---------------------------------------------------------------------------
for f in config.h config_components.h; do
  if [ -f "${FFMPEG_SRC}/${f}" ]; then
    cp "${FFMPEG_SRC}/${f}" "${OUT}/ffmpeg/${f}"
  fi
done
for f in configure.log make.log; do
  [ -f "${BUILD_ROOT}/${f}" ] && cp "${BUILD_ROOT}/${f}" "${OUT}/ffmpeg/${f}"
done
[ -f "${OUT}/ffmpeg/config.h" ] || die "缺少 config.h，无法提供无 GPL 的源码级证据"

# ---------------------------------------------------------------------------
# 4. 许可证文本（上游 COPYING + 仓库许可证与书面要约）
# ---------------------------------------------------------------------------
cp "${REPO_ROOT}/licenses/"*.txt "${OUT}/licenses/" 2>/dev/null || true
cp "${REPO_ROOT}/licenses/"*.md "${OUT}/licenses/" 2>/dev/null || true
for f in "${BUILD_ROOT}/ffmpeg-src/LICENSE.md" "${BUILD_ROOT}/ffmpeg-src/COPYING.LGPLv2.1" \
         "${BUILD_ROOT}/lame-build/COPYING" "${BUILD_ROOT}/opus-build/COPYING"; do
  if [ -f "$f" ]; then cp "$f" "${OUT}/licenses/upstream-$(basename "$f")"; fi
done
echo "许可证文本: $(ls -1 "${OUT}/licenses" | wc -l | tr -d ' ') 个文件"

# ---------------------------------------------------------------------------
# 5. 二进制指纹 + 构建记录
# ---------------------------------------------------------------------------
(cd "$BIN_DIR" && shasum -a 256 "ffmpeg-${TRIPLE}" "ffprobe-${TRIPLE}" > "${OUT}/BINARIES.sha256")

script_sha="$(shasum -a 256 "${REPO_ROOT}/scripts/build-ffmpeg-lgpl.sh" | cut -d' ' -f1)"
ffmpeg_sha="$(awk '/ffmpeg-/{print $1}' "${OUT}/BINARIES.sha256" | head -1)"
ffprobe_sha="$(awk '/ffprobe-/{print $1}' "${OUT}/BINARIES.sha256" | head -1)"
os_version="$(sw_vers -productVersion 2>/dev/null || echo unknown)"
clang_version="$(clang --version 2>/dev/null | head -1 || echo unknown)"

{
  echo "# FFmpeg LGPL 构建记录"
  echo "构建时间      : $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "主机          : $(uname -srm)"
  echo "macOS         : ${os_version}"
  echo "编译器        : ${clang_version}"
  echo "目标          : ${TRIPLE}"
  echo "FFmpeg        : ${FFMPEG_VERSION}"
  echo "LAME          : ${LAME_VERSION}"
  echo "libopus       : ${OPUS_VERSION}"
  echo "构建脚本 sha256: ${script_sha}"
  echo "ffmpeg  sha256 : ${ffmpeg_sha}"
  echo "ffprobe sha256 : ${ffprobe_sha}"
  echo "目标文件      : ${o_count} 个 .o / ${a_count} 个 .a"
  echo
  echo "## configure 参数（-buildconf）"
  "$FFMPEG_BIN" -hide_banner -buildconf 2>/dev/null || true
  echo
  echo "## 许可证声明（-L 前 6 行）"
  "$FFMPEG_BIN" -hide_banner -L 2>/dev/null | head -6 || true
  echo
  echo "## 动态依赖（otool -L）"
  otool -L "$FFMPEG_BIN" 2>/dev/null || true
} > "${OUT}/build-info.txt"

cat > "${OUT}/BUILD_RECORD.json" <<EOF
{
  "product": "VideoFlow",
  "component": "ffmpeg-lgpl",
  "target": "${TRIPLE}",
  "built_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "host": "$(uname -srm)",
  "macos_version": "${os_version}",
  "compiler": "${clang_version}",
  "versions": {
    "ffmpeg": "${FFMPEG_VERSION}",
    "lame": "${LAME_VERSION}",
    "libopus": "${OPUS_VERSION}"
  },
  "license": "LGPL-2.1-or-later",
  "configure_flags": ["--disable-gpl", "--disable-version3", "--disable-nonfree", "--disable-autodetect"],
  "external_libraries": [
    { "name": "LAME", "version": "${LAME_VERSION}", "license": "LGPL-2.0" },
    { "name": "libopus", "version": "${OPUS_VERSION}", "license": "BSD-3-Clause" }
  ],
  "relink_materials": { "objects": ${o_count:-0}, "archives": ${a_count:-0} },
  "build_script_sha256": "${script_sha}",
  "binaries": {
    "ffmpeg": "${ffmpeg_sha}",
    "ffprobe": "${ffprobe_sha}"
  }
}
EOF

echo
echo "材料目录: ${OUT}"
du -sh "$OUT" 2>/dev/null | awk '{print "体积    : "$1}'
echo "下一步: MATERIALS_DIR=${OUT} ./scripts/verify-ffmpeg-lgpl.sh"
