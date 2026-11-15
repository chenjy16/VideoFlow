#!/usr/bin/env bash
# 校验随包分发的 FFmpeg / FFprobe 是否仍是合规的静态 LGPL 构建。
#
# 三个场景必须跑同一份检查，缺一不可：
#   1. ffmpeg-lgpl.yml 缓存命中 —— 防止缓存里的旧产物绕过检查
#   2. ffmpeg-lgpl.yml 构建完成 —— 防止构建参数漂移
#   3. release.yml 打包前 —— 防止被别的二进制替换
#
# 用法：
#   ./scripts/verify-ffmpeg-lgpl.sh
#   MATERIALS_DIR=.build/ffmpeg-lgpl-materials ./scripts/verify-ffmpeg-lgpl.sh
#
# 刻意不用 set -e：所有检查都要跑完再汇总，否则第一个失败会掩盖后面的问题。
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN_DIR="${BIN_DIR:-${REPO_ROOT}/src-tauri/binaries}"
TRIPLE="${TRIPLE:-aarch64-apple-darwin}"
FFMPEG_VERSION="${FFMPEG_VERSION:-8.0.1}"
MATERIALS_DIR="${MATERIALS_DIR:-}"
EXPECT_OBJECTS="${EXPECT_OBJECTS:-589}"
EXPECT_ARCHIVES="${EXPECT_ARCHIVES:-8}"

# 后面要在 $BIN_DIR 里跑 shasum -c，材料路径必须是绝对路径，否则相对路径会失效
if [ -n "$MATERIALS_DIR" ] && [ -d "$MATERIALS_DIR" ]; then
  MATERIALS_DIR="$(cd "$MATERIALS_DIR" && pwd)"
fi

FFMPEG_BIN="${BIN_DIR}/ffmpeg-${TRIPLE}"
FFPROBE_BIN="${BIN_DIR}/ffprobe-${TRIPLE}"

CHECKS=0
FAILS=0
pass() { CHECKS=$((CHECKS + 1)); printf '  [PASS] %s\n' "$*"; }
fail() { CHECKS=$((CHECKS + 1)); FAILS=$((FAILS + 1)); printf '  [FAIL] %s\n' "$*"; }
# check <描述> <命令...>：命令成功即 PASS
check() {
  local desc="$1"
  shift
  if "$@" >/dev/null 2>&1; then pass "$desc"; else fail "$desc"; fi
}

echo "== FFmpeg / FFprobe LGPL 合规校验 =="
echo "二进制目录: ${BIN_DIR}"
echo "目标架构  : ${TRIPLE}"
echo

# ---------------------------------------------------------------------------
# 1. 存在性、可执行性、占位标记
# ---------------------------------------------------------------------------
for bin in "$FFMPEG_BIN" "$FFPROBE_BIN"; do
  name="$(basename "$bin")"
  check "${name} 存在且非空" test -s "$bin"
  check "${name} 可执行" test -x "$bin"
  if [ -f "$bin" ] && grep -qa 'VIDEOFLOW_CI_STUB' "$bin" 2>/dev/null; then
    fail "${name} 是 CI 编译期占位文件，不能用于发布"
  else
    pass "${name} 不是 CI 占位文件"
  fi
done

# 后面的检查都依赖二进制可运行，缺了就提前收尾
if [ ! -x "$FFMPEG_BIN" ] || [ ! -x "$FFPROBE_BIN" ]; then
  echo
  echo "结论: FAIL（${FAILS}/${CHECKS} 项失败）—— 二进制缺失，跳过后续检查"
  exit 1
fi

# ---------------------------------------------------------------------------
# 2. 架构（Apple Silicon 单架构）
# ---------------------------------------------------------------------------
for bin in "$FFMPEG_BIN" "$FFPROBE_BIN"; do
  name="$(basename "$bin")"
  archs="$(lipo -archs "$bin" 2>/dev/null || echo '?')"
  if [ "$archs" = "arm64" ]; then
    pass "${name} 架构为 arm64"
  else
    fail "${name} 架构为 '${archs}'，期望 arm64"
  fi
done

# ---------------------------------------------------------------------------
# 3. 版本
# ---------------------------------------------------------------------------
ffmpeg_v="$("$FFMPEG_BIN" -hide_banner -version 2>/dev/null | head -1)"
ffprobe_v="$("$FFPROBE_BIN" -hide_banner -version 2>/dev/null | head -1)"
case "$ffmpeg_v" in
  "ffmpeg version ${FFMPEG_VERSION} "*) pass "ffmpeg 版本为 ${FFMPEG_VERSION}" ;;
  *) fail "ffmpeg 版本不符: ${ffmpeg_v}" ;;
esac
case "$ffprobe_v" in
  "ffprobe version ${FFMPEG_VERSION} "*) pass "ffprobe 版本为 ${FFMPEG_VERSION}" ;;
  *) fail "ffprobe 版本不符: ${ffprobe_v}" ;;
esac

# ---------------------------------------------------------------------------
# 4. 许可证声明（-L）
# ---------------------------------------------------------------------------
license_text="$("$FFMPEG_BIN" -hide_banner -L 2>/dev/null || true)"
if printf '%s' "$license_text" | grep -q 'GNU Lesser General Public'; then
  pass "-L 声明 GNU Lesser General Public License"
else
  fail "-L 未声明 LGPL"
fi
if printf '%s' "$license_text" | grep -q 'version 2.1 of the License, or (at your option) any later version'; then
  pass "-L 声明 LGPL-2.1-or-later"
else
  fail "-L 未声明 LGPL-2.1-or-later"
fi
if printf '%s' "$license_text" | grep -qi 'version 3 of the License'; then
  fail "-L 出现 GPLv3 条款，与 --disable-version3 矛盾"
else
  pass "-L 未出现 GPLv3 条款"
fi

# ---------------------------------------------------------------------------
# 5. 构建配置（-buildconf）—— 不能只看 --disable-gpl，必须逐项断言
# ---------------------------------------------------------------------------
buildconf="$("$FFMPEG_BIN" -hide_banner -buildconf 2>/dev/null || true)"
for flag in --disable-gpl --disable-version3 --disable-nonfree --disable-autodetect --enable-static --disable-shared; do
  if printf '%s' "$buildconf" | grep -q -- "$flag"; then
    pass "buildconf 含 ${flag}"
  else
    fail "buildconf 缺少 ${flag}"
  fi
done
for flag in --enable-gpl --enable-version3 --enable-nonfree; do
  if printf '%s' "$buildconf" | grep -q -- "$flag"; then
    fail "buildconf 含禁止开关 ${flag}"
  else
    pass "buildconf 不含 ${flag}"
  fi
done

# 开发机构建的二进制会把个人主目录写进 configure 记录，不允许用于发布。
# CI 的 /Users/runner 是允许的，其它 /Users/<name> 一律视为泄漏。
dev_homes="$(printf '%s\n' "$buildconf" | grep -oE '/Users/[A-Za-z0-9._-]+' | sort -u | grep -v '^/Users/runner$' || true)"
if [ -n "$dev_homes" ]; then
  fail "buildconf 记录了非 CI 主目录: $(printf '%s' "$dev_homes" | tr '\n' ' ')"
else
  pass "buildconf 无开发机主目录路径"
fi
# 只在意链接/头文件目录里的 Homebrew 路径：那才是误链 GPL 库的真实风险。
# --pkg-config=/opt/homebrew/bin/pkg-config 只是构建工具位置，与链接无关，不算问题。
link_paths="$(printf '%s' "$buildconf" | sed 's|--pkg-config=[^ ]*||g')"
if printf '%s' "$link_paths" | grep -q '/opt/homebrew'; then
  fail "buildconf 的链接/头文件路径引用了 /opt/homebrew（存在误链 GPL 库的风险）"
else
  pass "buildconf 的链接路径未引用 Homebrew"
fi

# ---------------------------------------------------------------------------
# 6. 动态依赖：只允许系统库（静态 LGPL 的核心诉求）
# ---------------------------------------------------------------------------
for bin in "$FFMPEG_BIN" "$FFPROBE_BIN"; do
  name="$(basename "$bin")"
  bad_deps="$(otool -L "$bin" 2>/dev/null | tail -n +2 | awk '{print $1}' \
    | grep -vE '^(/usr/lib/|/System/Library/|/Library/Apple/)' || true)"
  if [ -n "$bad_deps" ]; then
    fail "${name} 依赖了非系统库: $(printf '%s' "$bad_deps" | tr '\n' ' ')"
  else
    pass "${name} 只依赖系统库"
  fi
done

# ---------------------------------------------------------------------------
# 7. 许可证材料（缓存命中 / 发布打包时必查）
# ---------------------------------------------------------------------------
if [ -n "$MATERIALS_DIR" ]; then
  echo
  echo "-- 许可证材料: ${MATERIALS_DIR} --"

  if [ -d "$MATERIALS_DIR" ]; then
    pass "材料目录存在"
  else
    fail "材料目录不存在: ${MATERIALS_DIR}"
  fi

  # 二进制必须与材料记录一致，否则说明缓存里的二进制和材料不是同一次构建
  if [ -f "${MATERIALS_DIR}/BINARIES.sha256" ]; then
    if (cd "$BIN_DIR" && shasum -a 256 -c "${MATERIALS_DIR}/BINARIES.sha256" >/dev/null 2>&1); then
      pass "二进制 sha256 与材料记录一致"
    else
      fail "二进制 sha256 与材料记录不一致（材料与二进制不是同一次构建）"
    fi
  else
    fail "缺少 BINARIES.sha256"
  fi

  # config.h 三个开关必须为 0：这是"无 GPL/GPLv3/nonfree 组件"的源码级证据
  config_h="${MATERIALS_DIR}/ffmpeg/config.h"
  if [ -f "$config_h" ]; then
    for macro in CONFIG_GPL CONFIG_VERSION3 CONFIG_NONFREE; do
      if grep -qx "#define ${macro} 0" "$config_h"; then
        pass "config.h 中 ${macro} 为 0"
      else
        fail "config.h 中 ${macro} 不为 0"
      fi
    done
  else
    fail "缺少 ffmpeg/config.h"
  fi

  # 再链接材料：目标文件数量与两个第三方静态库
  obj_tar="${MATERIALS_DIR}/objects/objects.tar.gz"
  if [ -f "$obj_tar" ]; then
    o_count="$(tar tzf "$obj_tar" 2>/dev/null | grep -c '\.o$' || true)"
    a_count="$(tar tzf "$obj_tar" 2>/dev/null | grep -c '\.a$' || true)"
    if [ "${o_count:-0}" -ge "$EXPECT_OBJECTS" ]; then
      pass "目标文件 ${o_count} 个（要求 ≥ ${EXPECT_OBJECTS}）"
    else
      fail "目标文件只有 ${o_count} 个（要求 ≥ ${EXPECT_OBJECTS}）"
    fi
    if [ "${a_count:-0}" -ge "$EXPECT_ARCHIVES" ]; then
      pass "静态库 ${a_count} 个（要求 ≥ ${EXPECT_ARCHIVES}）"
    else
      fail "静态库只有 ${a_count} 个（要求 ≥ ${EXPECT_ARCHIVES}）"
    fi
    for lib in libmp3lame.a libopus.a; do
      if tar tzf "$obj_tar" 2>/dev/null | grep -q "/${lib}$"; then
        pass "包含再链接所需的 ${lib}"
      else
        fail "缺少再链接所需的 ${lib}"
      fi
    done
  else
    fail "缺少 objects/objects.tar.gz"
  fi

  # 上游与仓库许可证文本
  for f in FFmpeg-LGPL-2.1.txt FFmpeg-LICENSE.md LAME-LGPL-2.0.txt libopus-BSD-3-Clause.txt SOURCE_OFFER.txt; do
    check "许可证材料含 ${f}" test -s "${MATERIALS_DIR}/licenses/${f}"
  done

  # 构建记录：可审计的最小要求
  for f in BUILD_RECORD.json build-info.txt; do
    check "构建记录含 ${f}" test -s "${MATERIALS_DIR}/${f}"
  done

  # 原始源码包（LGPL §6 源码可得性）
  for f in "ffmpeg-${FFMPEG_VERSION}.tar.xz"; do
    check "源码包含 ${f}" test -s "${MATERIALS_DIR}/sources/${f}"
  done
  if [ -f "${MATERIALS_DIR}/sources/SHA256SUMS" ]; then
    if (cd "${MATERIALS_DIR}/sources" && shasum -a 256 -c SHA256SUMS >/dev/null 2>&1); then
      pass "源码包 sha256 校验通过"
    else
      fail "源码包 sha256 校验失败"
    fi
  else
    fail "缺少 sources/SHA256SUMS"
  fi
fi

# ---------------------------------------------------------------------------
# 汇总
# ---------------------------------------------------------------------------
echo
if [ "$FAILS" -eq 0 ]; then
  echo "结论: PASS（${CHECKS} 项检查全部通过）"
  exit 0
fi
echo "结论: FAIL（${FAILS}/${CHECKS} 项失败）"
exit 1
