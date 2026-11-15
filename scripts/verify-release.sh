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
#   NOTARIZATION_STATUS   由 notarize.sh 从 Apple 返回的 JSON 写入；为 true 时必须为 ACCEPTED
#   INTERNAL_BUILD        默认 false；为 true 时只能是 unsigned 内部测试包（报告首行会醒目标记）
#   TEST_RELEASE          默认 false；为 true 时是 tag 测试发行：必须 unsigned + 未公证，且不得带任何公证痕迹
#   EXPECTED_SIGNING_IDENTITY  developer-id 模式下期望的签名身份全名（由 import-signing-certificate.sh 回填）
#   EXPECTED_TEAM_ID           developer-id 模式下期望的 Team ID（同上）
#   EXPECTED_VERSION      若设置则校验 CFBundleShortVersionString
#   REPORT_PATH           校验报告输出路径
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TRIPLE="${TRIPLE:-aarch64-apple-darwin}"
BUNDLE_DIR="${BUNDLE_DIR:-${REPO_ROOT}/src-tauri/target/${TRIPLE}/release/bundle}"
SIGNING_MODE="${SIGNING_MODE:-unsigned}"
ALLOW_UNSIGNED="${ALLOW_UNSIGNED:-0}"
REQUIRE_NOTARIZATION="${REQUIRE_NOTARIZATION:-false}"
INTERNAL_BUILD="${INTERNAL_BUILD:-false}"
TEST_RELEASE="${TEST_RELEASE:-false}"
NOTARIZATION_STATUS="${NOTARIZATION_STATUS:-}"
EXPECTED_SIGNING_IDENTITY="${EXPECTED_SIGNING_IDENTITY:-}"
EXPECTED_TEAM_ID="${EXPECTED_TEAM_ID:-}"
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
if [ "$INTERNAL_BUILD" = "true" ]; then echo "构建类型: INTERNAL TEST BUILD - NOT NOTARIZED"; fi
if [ "$TEST_RELEASE" = "true" ]; then echo "构建类型: TEST RELEASE - UNSIGNED - NOT NOTARIZED"; fi
echo

# 内部测试包必须是不签名 + 显式放行的，三条任意一条不满足就是配置错了
if [ "$INTERNAL_BUILD" = "true" ]; then
  if [ "$REQUIRE_NOTARIZATION" = "true" ]; then
    fail "INTERNAL_BUILD=true 却要求公证，配置矛盾"
  fi
  if [ "$SIGNING_MODE" != "unsigned" ]; then
    fail "INTERNAL_BUILD=true 但签名模式为 ${SIGNING_MODE}，内部测试包只能未签名（需在 validate 阶段强制 unsigned）"
  fi
  if [ "$ALLOW_UNSIGNED" != "1" ]; then
    fail "INTERNAL_BUILD=true 但 ALLOW_UNSIGNED=${ALLOW_UNSIGNED}，未显式放行"
  fi
fi

# tag 测试发行：unsigned + 未公证，且不允许出现任何“已公证”的痕迹
if [ "$TEST_RELEASE" = "true" ]; then
  if [ "$INTERNAL_BUILD" = "true" ]; then
    fail "TEST_RELEASE 与 INTERNAL_BUILD 互斥（两种发布模式不能同时开启）"
  fi
  if [ "$REQUIRE_NOTARIZATION" = "true" ]; then
    fail "TEST_RELEASE=true 却要求公证，配置矛盾"
  fi
  if [ "$SIGNING_MODE" != "unsigned" ]; then
    fail "TEST_RELEASE=true 但签名模式为 ${SIGNING_MODE}，测试发行必须 unsigned"
  fi
  if [ "$ALLOW_UNSIGNED" != "1" ]; then
    fail "TEST_RELEASE=true 但 ALLOW_UNSIGNED=${ALLOW_UNSIGNED}，未显式放行"
  fi
  case "$NOTARIZATION_STATUS" in
    ""|NOT_NOTARIZED) pass "测试发行公证状态为 NOT_NOTARIZED（未启用 Apple Notarization）" ;;
    ACCEPTED) fail "TEST_RELEASE 声称 ACCEPTED，但这是 unsigned 未公证构建；拒绝伪造公证状态" ;;
    *) fail "TEST_RELEASE 的公证状态为 ${NOTARIZATION_STATUS}，只允许 NOT_NOTARIZED" ;;
  esac
fi

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
  # 3.1 .app 深度校验：主程序 + 全部嵌套二进制（sidecar）都必须签名有效
  if codesign --verify --deep --strict "$APP" >/dev/null 2>&1; then
    pass "codesign --verify --deep --strict 通过（.app）"
  else
    fail ".app 签名校验失败（codesign --verify --deep --strict）"
  fi

  # 3.2 签名主体、身份、Hardened Runtime、时间戳、Team ID
  app_sign="$(codesign -dv --verbose=2 "$APP" 2>&1)"
  info "签名信息(.app): $(printf '%s' "$app_sign" | tr '\n' ' ')"
  if printf '%s\n' "$app_sign" | grep -q '^Authority=Developer ID Application'; then
    pass "签名为 Developer ID Application"
  else
    fail "未使用 Developer ID Application 签名"
  fi
  if [ -n "$EXPECTED_SIGNING_IDENTITY" ]; then
    if printf '%s\n' "$app_sign" | grep -qxF "Authority=${EXPECTED_SIGNING_IDENTITY}"; then
      pass "签名身份与期望一致"
    else
      fail "签名身份与期望不一致，期望 '${EXPECTED_SIGNING_IDENTITY}'"
    fi
  else
    info "未提供 EXPECTED_SIGNING_IDENTITY，仅校验证书类型"
  fi
  # 必须是 Apple 签发的 Developer ID 证书链：防自签名、同名证书冒充
  if printf '%s\n' "$app_sign" | grep -qxF 'Authority=Developer ID Certification Authority'; then
    pass "证书链来自 Apple Developer ID CA"
  else
    fail "证书链不是 Apple Developer ID CA（可能为自签名或链不完整）"
  fi
  if printf '%s\n' "$app_sign" | grep -q 'flags=0x10000'; then
    pass "启用 Hardened Runtime（flags=0x10000）"
  else
    fail "未检测到 Hardened Runtime 标记"
  fi
  # 公证与可信分发都要求安全时间戳；缺失通常说明构建机没联网或显式 --timestamp=none
  if printf '%s\n' "$app_sign" | grep -q '^Timestamp='; then
    pass "签名包含安全时间戳"
  else
    fail "签名缺少安全时间戳（Timestamp）"
  fi
  app_team="$(printf '%s\n' "$app_sign" | sed -n 's/^TeamIdentifier=//p' | head -1)"
  if [ -n "$EXPECTED_TEAM_ID" ]; then
    [ "$app_team" = "$EXPECTED_TEAM_ID" ] \
      && pass ".app Team ID 为 ${app_team}" \
      || fail ".app Team ID 为 '${app_team:-<空>}'，期望 ${EXPECTED_TEAM_ID}"
  else
    info ".app Team ID: ${app_team:-<空>}"
  fi

  # 3.3 DMG 自身也必须有签名：用户双击的是 DMG，未签名的 DMG 会被 Gatekeeper 直接拦下
  if codesign --verify --strict "$DMG" >/dev/null 2>&1; then
    pass "codesign --verify --strict 通过（.dmg）"
  else
    fail ".dmg 签名校验失败"
  fi
  dmg_sign="$(codesign -dv --verbose=2 "$DMG" 2>&1)"
  if printf '%s\n' "$dmg_sign" | grep -q '^Authority=Developer ID Application'; then
    pass ".dmg 由 Developer ID Application 签名"
  else
    fail ".dmg 未使用 Developer ID Application 签名"
  fi
  dmg_team="$(printf '%s\n' "$dmg_sign" | sed -n 's/^TeamIdentifier=//p' | head -1)"
  if [ -n "$app_team" ] && [ -n "$dmg_team" ]; then
    [ "$app_team" = "$dmg_team" ] \
      && pass ".app 与 .dmg 的 Team ID 一致（${app_team}）" \
      || fail "Team ID 不一致：.app=${app_team} .dmg=${dmg_team}"
  fi

  # 3.4 entitlement：yt-dlp 是 PyInstaller onefile，Hardened Runtime 下必须能加载
  # 异 Team ID 的内嵌 framework，否则 sidecar 直接 exit=255（见 docs/NOTARIZATION.md）
  ENT_KEY='com.apple.security.cs.disable-library-validation'
  if codesign -d --entitlements :- "$APP" 2>/dev/null | grep -qF "$ENT_KEY"; then
    pass "主程序 entitlement 含 disable-library-validation"
  else
    fail "主程序缺少 ${ENT_KEY}，yt-dlp onefile 在当前签名配置下无法运行"
  fi
  if codesign -d --entitlements :- "${APP}/Contents/MacOS/yt-dlp" 2>/dev/null | grep -qF "$ENT_KEY"; then
    pass "sidecar yt-dlp entitlement 含 disable-library-validation"
  else
    fail "sidecar yt-dlp 缺少 ${ENT_KEY}，下载引擎会 exit=255"
  fi
else
  if [ "$ALLOW_UNSIGNED" = "1" ]; then
    pass "未签名产物，已按内部测试 Artifact 放行（ALLOW_UNSIGNED=1）"
  else
    fail "产物未签名且未允许未签名发布（ALLOW_UNSIGNED=${ALLOW_UNSIGNED}）"
  fi
  info "签名状态: AD_HOC（无 Developer ID）"

  # unsigned 不等于没有签名：.app 自身必须是完整的 ad-hoc 签名（主程序 + 全部 sidecar
  # + Info.plist 绑定）。只有链接器签名时 codesign --verify 失败，用户从浏览器下载后
  # 带 quarantine 启动会直接弹「“VideoFlow.app”已损坏」，xattr 去隔离也修不回来。
  if codesign --verify --deep --strict "$APP" >/dev/null 2>&1; then
    pass "codesign --verify --deep --strict 通过（ad-hoc .app）"
  else
    fail ".app 签名不完整（codesign --verify --deep --strict 失败）——下载后会被 macOS 报「已损坏」"
  fi
  app_sign="$(codesign -dv --verbose=2 "$APP" 2>&1 || true)"
  info "签名信息(.app): $(printf '%s' "$app_sign" | tr '\n' ' ')"
  if printf '%s\n' "$app_sign" | grep -q '^Signature=adhoc'; then
    pass ".app 已完成 ad-hoc 签名（Signature=adhoc）"
  else
    fail ".app 缺少 ad-hoc 签名（可能根本没做过 codesign）"
  fi
  if printf '%s\n' "$app_sign" | grep -q '^Info.plist entries='; then
    pass "ad-hoc 签名已绑定 Info.plist 与资源清单"
  else
    fail "签名未绑定 Info.plist（只有链接器签名，bundle 未真正 codesign）"
  fi

  # 测试发行的“unsigned”声明必须与产物一致：只要出现 Developer ID 签发就不能叫 unsigned
  if [ "$TEST_RELEASE" = "true" ]; then
    app_auth="$(codesign -dv --verbose=2 "$APP" 2>&1 || true)"
    if printf '%s\n' "$app_auth" | grep -q '^Authority=Developer ID Application'; then
      fail "测试发行的 .app 带 Developer ID 签名，与 unsigned 声明矛盾"
    else
      pass "测试发行的 .app 未经 Developer ID 签名（unsigned）"
    fi
    dmg_auth="$(codesign -dv --verbose=2 "$DMG" 2>&1 || true)"
    if printf '%s\n' "$dmg_auth" | grep -q '^Authority=Developer ID Application'; then
      fail "测试发行的 .dmg 带 Developer ID 签名，与 unsigned 声明矛盾"
    else
      pass "测试发行的 .dmg 未经 Developer ID 签名（unsigned）"
    fi
  fi
fi

# Gatekeeper 评估只记录，具体判定放在第 4 节：
#   * unsigned            → 必然 rejected
#   * developer-id 未公证 → rejected source=Unnotarized Developer ID
#   * 已公证 + 已 staple   → accepted source=Notarized Developer ID
spctl_out="$(spctl --assess --type execute --verbose=4 "$APP" 2>&1 | tr '\n' ' ')"
info "spctl: ${spctl_out}"
if [ "$SIGNING_MODE" = "developer-id" ] && [ "$REQUIRE_NOTARIZATION" != "true" ] \
   && printf '%s' "$spctl_out" | grep -q 'Unnotarized Developer ID'; then
  info "Gatekeeper 为未公证的预期状态；公证后应变更为 accepted"
fi

# ---------------------------------------------------------------------------
# 4. 公证状态（数据来源必须是 Apple 的真实返回，不接受任何硬编码）
# ---------------------------------------------------------------------------
if [ "$REQUIRE_NOTARIZATION" = "true" ]; then
  # 用户下载的 DMG 必须带装订票据
  if xcrun stapler validate "$DMG" >/dev/null 2>&1; then
    pass "公证票据已装订（stapler validate，.dmg）"
  else
    fail "REQUIRE_NOTARIZATION=true 但 stapler validate 未通过（.dmg）"
  fi
  # 打进 .app.zip 的应用包同样必须有票据
  BUNDLE_APP="${BUNDLE_DIR}/macos/${PRODUCT}.app"
  if [ -d "$BUNDLE_APP" ]; then
    if xcrun stapler validate "$BUNDLE_APP" >/dev/null 2>&1; then
      pass "公证票据已装订（stapler validate，.app）"
    else
      fail "REQUIRE_NOTARIZATION=true 但 stapler validate 未通过（.app）"
    fi
  else
    info "未找到 ${BUNDLE_APP}，跳过 .app 票据校验"
  fi
  # 状态必须等于 notarize.sh 从 notarytool 输出里取到的值
  case "$NOTARIZATION_STATUS" in
    ACCEPTED) pass "公证状态取自 Apple 返回：ACCEPTED" ;;
    "") info "未提供 NOTARIZATION_STATUS，跳过状态一致性校验" ;;
    *) fail "公证状态为 ${NOTARIZATION_STATUS}，不是 Apple 返回的 ACCEPTED" ;;
  esac
  if printf '%s' "$spctl_out" | grep -q ': accepted'; then
    pass "Gatekeeper 评估通过（spctl accepted）"
  else
    fail "REQUIRE_NOTARIZATION=true 但 spctl 未返回 accepted：${spctl_out}"
  fi
else
  info "公证状态: NOT_NOTARIZED（未启用 Apple Notarization）"
  if [ "$TEST_RELEASE" = "true" ]; then
    if xcrun stapler validate "$DMG" >/dev/null 2>&1; then
      fail "测试发行的 DMG 携带公证票据，与 unsigned 声明矛盾（不允许伪造 Staple）"
    else
      pass "测试发行的 DMG 不含公证票据（预期）"
    fi
    bundle_app="${BUNDLE_DIR}/macos/${PRODUCT}.app"
    if [ -d "$bundle_app" ]; then
      if xcrun stapler validate "$bundle_app" >/dev/null 2>&1; then
        fail "测试发行的 .app 携带公证票据，与 unsigned 声明矛盾"
      else
        pass "测试发行的 .app 不含公证票据（预期）"
      fi
    fi
  fi
fi

# ---------------------------------------------------------------------------
# 汇总
# ---------------------------------------------------------------------------
{
  echo "VideoFlow 发布校验报告"
  if [ "$INTERNAL_BUILD" = "true" ]; then
    echo "INTERNAL TEST BUILD - NOT NOTARIZED"
  fi
  if [ "$TEST_RELEASE" = "true" ]; then
    echo "TEST RELEASE - UNSIGNED - NOT NOTARIZED"
  fi
  echo "时间    : $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "目标    : ${TRIPLE}"
  echo "签名    : ${SIGNING_MODE}"
  echo "公证    : $( [ "$REQUIRE_NOTARIZATION" = "true" ] && echo REQUIRED || echo NOT_NOTARIZED )"
  echo "公证状态: ${NOTARIZATION_STATUS:-NOT_NOTARIZED}"
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
