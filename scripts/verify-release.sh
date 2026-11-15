#!/usr/bin/env bash
# 校验 Tauri 产出的 .app / .dmg 是否可发布：架构、引擎、许可证、签名、公证状态。
#
# 校验对象是 DMG 里挂载出来的 .app —— 也就是用户真正拷进 /Applications 的那一份，
# 而不是 target 目录里的中间产物。
#
# 环境变量：
#   BUNDLE_DIR            默认 src-tauri/target/<triple>/release/bundle
#   TRIPLE                默认 aarch64-apple-darwin
#   SIGNING_MODE          unsigned | developer-id
#   ALLOW_UNSIGNED        未签名时是否放行（内部测试 Artifact 用 1，正式发布必须为 0）
#   REQUIRE_NOTARIZATION  默认 false；为 true 时必须 stapler validate 通过
#   EXPECTED_VERSION      若设置则校验 CFBundleShortVersionString
#   REPORT_PATH           校验报告输出路径
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TRIPLE="${TRIPLE:-aarch64-apple-darwin}"
BUNDLE_DIR="${BUNDLE_DIR:-${REPO_ROOT}/src-tauri/target/${TRIPLE}/release/bundle}"
SIGNING_MODE="${SIGNING_MODE:-unsigned}"
ALLOW_UNSIGNED="${ALLOW_UNSIGNED:-0}"
REQUIRE_NOTARIZATION="${REQUIRE_NOTARIZATION:-false}"
EXPECTED_VERSION="${EXPECTED_VERSION:-}"
REPORT_PATH="${REPORT_PATH:-${REPO_ROOT}/verification-report.txt}"

PRODUCT="$(sed -n 's/^  "productName": "\(.*\)",$/\1/p' "${REPO_ROOT}/src-tauri/tauri.conf.json" | head -1)"
[ -n "$PRODUCT" ] || PRODUCT="VideoFlow"
EXPECTED_BUNDLE_ID="$(sed -n 's/^  "identifier": "\(.*\)",$/\1/p' "${REPO_ROOT}/src-tauri/tauri.conf.json" | head -1)"
EXPECTED_MIN_OS="$(sed -n 's/.*"minimumSystemVersion": "\(.*\)".*/\1/p' "${REPO_ROOT}/src-tauri/tauri.conf.json" | head -1)"

CHECKS=0
FAILS=0
REPORT=""
note() {
  local line="  [$1] $2"
  echo "$line"
  REPORT="${REPORT}${line}"$'\n'
}
pass() { CHECKS=$((CHECKS + 1)); note PASS "$*"; }
fail() { CHECKS=$((CHECKS + 1)); FAILS=$((FAILS + 1)); note FAIL "$*"; }
info() { note INFO "$*"; }
check() {
  local desc="$1"
  shift
  if "$@" >/dev/null 2>&1; then pass "$desc"; else fail "$desc"; fi
}

DMG="$(find "${BUNDLE_DIR}/dmg" -maxdepth 1 -name '*.dmg' 2>/dev/null | head -1)"

echo "== 发布产物校验 =="
echo "bundle  : ${BUNDLE_DIR}"
echo "dmg     : ${DMG:-<未找到>}"
echo "签名模式: ${SIGNING_MODE}"
echo "公证要求: ${REQUIRE_NOTARIZATION}"
echo

if [ -z "$DMG" ] || [ ! -f "$DMG" ]; then
  echo "结论: FAIL —— 找不到 DMG，无法继续"
  exit 1
fi

# ---------------------------------------------------------------------------
# 1. DMG 自身完整性
# ---------------------------------------------------------------------------
if hdiutil verify "$DMG" >/dev/null 2>&1; then
  pass "DMG 完整性校验通过（hdiutil verify）"
else
  fail "DMG 完整性校验失败"
fi

# ---------------------------------------------------------------------------
# 2. 挂载 DMG，检查用户实际拿到的 .app
# ---------------------------------------------------------------------------
MNT="$(mktemp -d /tmp/vf-dmg-XXXXXX)"
detach() { hdiutil detach "$MNT" -quiet >/dev/null 2>&1 || true; rmdir "$MNT" 2>/dev/null || true; }
trap detach EXIT

if hdiutil attach "$DMG" -nobrowse -readonly -mountpoint "$MNT" >/dev/null 2>&1; then
  pass "DMG 挂载成功"
else
  fail "DMG 挂载失败"
  echo
  echo "结论: FAIL —— 无法挂载 DMG"
  exit 1
fi

APP="$(find "$MNT" -maxdepth 1 -name '*.app' | head -1)"
if [ -n "$APP" ] && [ -d "$APP" ]; then
  pass "DMG 内含 ${PRODUCT}.app"
else
  fail "DMG 内没有 .app"
  echo
  echo "结论: FAIL —— DMG 内容异常"
  exit 1
fi
info "挂载路径: $APP"

# 2.1 Info.plist：标识、版本、最低系统
PLIST="${APP}/Contents/Info.plist"
PB=/usr/libexec/PlistBuddy
if [ -f "$PLIST" ]; then
  bid="$($PB -c 'Print :CFBundleIdentifier' "$PLIST" 2>/dev/null)"
  ver="$($PB -c 'Print :CFBundleShortVersionString' "$PLIST" 2>/dev/null)"
  minos="$($PB -c 'Print :LSMinimumSystemVersion' "$PLIST" 2>/dev/null)"
  [ "$bid" = "$EXPECTED_BUNDLE_ID" ] && pass "Bundle ID 为 ${bid}" || fail "Bundle ID 为 ${bid}，期望 ${EXPECTED_BUNDLE_ID}"
  if [ -n "$EXPECTED_VERSION" ]; then
    [ "$ver" = "$EXPECTED_VERSION" ] && pass "版本号为 ${ver}" || fail "版本号为 ${ver}，期望 ${EXPECTED_VERSION}"
  else
    info "版本号: ${ver}"
  fi
  [ "$minos" = "$EXPECTED_MIN_OS" ] && pass "最低系统版本为 ${minos}" || fail "最低系统版本为 ${minos}，期望 ${EXPECTED_MIN_OS}"
else
  fail "缺少 Info.plist"
fi

# 2.2 主程序与全部 Mach-O 的架构
# 策略：
#   * VideoFlow 主程序与 ffmpeg/ffprobe 由我们构建，必须严格 arm64 单架构
#   * yt-dlp 是上游 PyInstaller 产物，官方 yt-dlp_macos 就是 universal2，
#     只有 lipo -thin 才能变单架构。为了保持上游产物可追溯、sha256 可校验，
#     不擅改第三方二进制；但必须包含 arm64 原生 slice，只剩 x86_64 一律失败。
MAIN_BIN="${APP}/Contents/MacOS/${PRODUCT}"
if [ -x "$MAIN_BIN" ]; then
  archs="$(lipo -archs "$MAIN_BIN" 2>/dev/null)"
  [ "$archs" = "arm64" ] && pass "主程序架构为 arm64" || fail "主程序架构为 '${archs}'，期望严格 arm64"
else
  fail "缺少主程序: Contents/MacOS/${PRODUCT}"
fi

bad_arch=()
universal_files=()
while IFS= read -r f; do
  if file -b "$f" 2>/dev/null | grep -q 'Mach-O'; then
    rel="${f#"$APP/"}"
    a="$(lipo -archs "$f" 2>/dev/null)"
    case " ${a} " in
      *" arm64 "*)
        # 含 arm64 但不是单架构，才是 universal2，单独记录以便审计
        if [ "$a" != "arm64" ]; then universal_files+=("${rel}:${a}"); fi
        ;;
      *) bad_arch+=("${rel}:${a:-unknown}") ;;
    esac
  fi
done < <(find "${APP}/Contents" -type f 2>/dev/null)
if [ "${#bad_arch[@]}" -eq 0 ]; then
  pass "App 内所有 Mach-O 文件均包含 arm64 原生 slice"
else
  fail "存在不含 arm64 的 Mach-O（无法在 Apple Silicon 原生运行）: $(printf '%s ' "${bad_arch[@]}")"
fi
if [ "${#universal_files[@]}" -gt 0 ]; then
  info "universal2 文件（含 arm64，已放行）: $(printf '%s ' "${universal_files[@]}")"
fi

# 2.3 三个 sidecar：存在、可执行、架构、非占位、版本可读
for tool in yt-dlp ffmpeg ffprobe; do
  bin="${APP}/Contents/MacOS/${tool}"
  if [ -f "$bin" ] && [ -x "$bin" ]; then pass "sidecar ${tool} 存在且可执行"; else fail "缺少 sidecar ${tool}"; continue; fi
  a="$(lipo -archs "$bin" 2>/dev/null)"
  if [ "$tool" = "yt-dlp" ]; then
    case " $a " in
      *" arm64 "*) pass "sidecar yt-dlp 含 arm64 原生 slice（${a}）" ;;
      *) fail "sidecar yt-dlp 架构为 '${a}'，缺少 arm64" ;;
    esac
  else
    [ "$a" = "arm64" ] && pass "sidecar ${tool} 架构为严格 arm64" || fail "sidecar ${tool} 架构为 '${a}'，期望严格 arm64"
  fi
  if grep -qa 'VIDEOFLOW_CI_STUB' "$bin" 2>/dev/null; then
    fail "sidecar ${tool} 是 CI 占位文件，绝不能发布"
  else
    pass "sidecar ${tool} 不是 CI 占位文件"
  fi
done
YDL_V="$("${APP}/Contents/MacOS/yt-dlp" --version 2>/dev/null | head -1)"
FFM_V="$("${APP}/Contents/MacOS/ffmpeg" -hide_banner -version 2>/dev/null | sed -n 's/^ffmpeg version \([^ ]*\).*/\1/p' | head -1)"
FFP_V="$("${APP}/Contents/MacOS/ffprobe" -hide_banner -version 2>/dev/null | sed -n 's/^ffprobe version \([^ ]*\).*/\1/p' | head -1)"
info "引擎版本: yt-dlp=${YDL_V} ffmpeg=${FFM_V} ffprobe=${FFP_V}"
[ -n "$YDL_V" ] && pass "yt-dlp 可运行" || fail "yt-dlp 无法运行（架构或签名问题）"
[ -n "$FFM_V" ] && pass "ffmpeg 可运行" || fail "ffmpeg 无法运行（架构或签名问题）"
[ -n "$FFP_V" ] && pass "ffprobe 可运行" || fail "ffprobe 无法运行（架构或签名问题）"

# ffmpeg 仍须是 LGPL 构建（详细材料校验在 verify-ffmpeg-lgpl.sh，这里做发布端兜底）
FFM_LICENSE="$("${APP}/Contents/MacOS/ffmpeg" -hide_banner -L 2>/dev/null | grep -c 'GNU Lesser General Public' || true)"
[ "${FFM_LICENSE:-0}" -ge 1 ] && pass "随包 ffmpeg 声明 LGPL" || fail "随包 ffmpeg 未声明 LGPL"

# 2.4 许可证资源
RES_LIC="${APP}/Contents/Resources/LICENSES"
if [ -d "$RES_LIC" ]; then
  pass "App 内含 LICENSES 资源目录"
  n="$(find "$RES_LIC" -maxdepth 1 -type f | wc -l | tr -d ' ')"
  [ "$n" -ge 6 ] && pass "许可证文件 ${n} 个（≥6）" || fail "许可证文件只有 ${n} 个"
  for f in FFmpeg-LGPL-2.1.txt LAME-LGPL-2.0.txt libopus-BSD-3-Clause.txt SOURCE_OFFER.txt; do
    check "许可证资源含 ${f}" test -s "${RES_LIC}/${f}"
  done
  if grep -q 'LGPL' "${RES_LIC}/SOURCE_OFFER.txt" 2>/dev/null; then
    pass "SOURCE_OFFER.txt 提及 LGPL 义务"
  else
    fail "SOURCE_OFFER.txt 内容异常"
  fi
else
  fail "App 内缺少 Contents/Resources/LICENSES"
fi

# ---------------------------------------------------------------------------
# 3. 签名
# ---------------------------------------------------------------------------
if [ "$SIGNING_MODE" = "developer-id" ]; then
  if codesign --verify --deep --strict "$APP" >/dev/null 2>&1; then
    pass "codesign --verify --deep --strict 通过"
  else
    fail "签名校验失败"
  fi
  sign_info="$(codesign -dv --verbose=2 "$APP" 2>&1 | tr '\n' ' ')"
  info "签名信息: ${sign_info}"
  if printf '%s' "$sign_info" | grep -q 'Developer ID Application'; then
    pass "签名为 Developer ID Application"
  else
    fail "未使用 Developer ID Application 签名"
  fi
  if printf '%s' "$sign_info" | grep -q 'flags=0x10000'; then
    pass "启用 Hardened Runtime（flags=0x10000）"
  else
    fail "未检测到 Hardened Runtime 标记"
  fi
else
  if [ "$ALLOW_UNSIGNED" = "1" ]; then
    pass "未签名产物，已按内部测试 Artifact 放行（ALLOW_UNSIGNED=1）"
  else
    fail "产物未签名且未允许未签名发布（ALLOW_UNSIGNED=${ALLOW_UNSIGNED}）"
  fi
  info "签名状态: NOT_SIGNED"
fi

# Gatekeeper 评估：未公证时必然 rejected，只记录不判失败
spctl_out="$(spctl --assess --type execute --verbose=4 "$APP" 2>&1 | tr '\n' ' ')"
info "spctl: ${spctl_out}"

# ---------------------------------------------------------------------------
# 4. 公证状态
# ---------------------------------------------------------------------------
if [ "$REQUIRE_NOTARIZATION" = "true" ]; then
  if xcrun stapler validate "$DMG" >/dev/null 2>&1; then
    pass "公证票据已装订（stapler validate）"
  else
    fail "REQUIRE_NOTARIZATION=true 但 stapler validate 未通过"
  fi
else
  info "公证状态: NOT_NOTARIZED（本阶段未启用 Apple Notarization）"
fi

# ---------------------------------------------------------------------------
# 汇总
# ---------------------------------------------------------------------------
{
  echo "VideoFlow 发布校验报告"
  echo "时间    : $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "目标    : ${TRIPLE}"
  echo "签名    : ${SIGNING_MODE}"
  echo "公证    : $( [ "$REQUIRE_NOTARIZATION" = "true" ] && echo REQUIRED || echo NOT_NOTARIZED )"
  echo
  echo "${REPORT}"
} > "$REPORT_PATH" 2>/dev/null || true

echo
if [ "$FAILS" -eq 0 ]; then
  echo "结论: PASS（${CHECKS} 项检查全部通过）"
  exit 0
fi
echo "结论: FAIL（${FAILS}/${CHECKS} 项失败）"
exit 1
