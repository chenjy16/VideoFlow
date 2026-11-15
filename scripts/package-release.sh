#!/usr/bin/env bash
# 把 tauri build 的产物整理成可发布的目录：DMG、.app 压缩包、许可证、清单、SHA256SUMS。
#
# 用法（通常由 release.yml 调用）：
#   VERSION=0.1.0 SIGNING_MODE=unsigned NOTARIZATION_STATUS=NOT_NOTARIZED \
#     ./scripts/package-release.sh
#
# 环境变量：
#   VERSION               版本号，默认从 package.json 读取
#   TRIPLE                默认 aarch64-apple-darwin
#   SIGNING_MODE          unsigned | developer-id
#   NOTARIZATION_STATUS   BLOCKED / NOT_NOTARIZED / ACCEPTED / INVALID / REJECTED ...（取自 Apple 返回）
#   NOTARIZATION_SUBMISSION_ID   notarytool 返回的 submission ID
#   REQUIRE_NOTARIZATION  默认 false
#   INTERNAL_BUILD        默认 false；为 true 时产出内部测试包（文件名/包内/清单三处标记 NOT NOTARIZED）
#   TEST_RELEASE          默认 false；为 true 时产出 tag 测试发行包（文件名/包内/清单标记 TEST RELEASE - UNSIGNED）
#   BUNDLE_DIR            默认 src-tauri/target/<triple>/release/bundle
#   OUT_DIR               默认 dist-release
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TRIPLE="${TRIPLE:-aarch64-apple-darwin}"
OUT_DIR="${OUT_DIR:-${REPO_ROOT}/dist-release}"
BUNDLE_DIR="${BUNDLE_DIR:-${REPO_ROOT}/src-tauri/target/${TRIPLE}/release/bundle}"
SIGNING_MODE="${SIGNING_MODE:-unsigned}"
NOTARIZATION_STATUS="${NOTARIZATION_STATUS:-NOT_NOTARIZED}"
NOTARIZATION_SUBMISSION_ID="${NOTARIZATION_SUBMISSION_ID:-}"
REQUIRE_NOTARIZATION="${REQUIRE_NOTARIZATION:-false}"
INTERNAL_BUILD="${INTERNAL_BUILD:-false}"
TEST_RELEASE="${TEST_RELEASE:-false}"
COMMIT_SHA="${COMMIT_SHA:-$(git -C "$REPO_ROOT" rev-parse --short HEAD 2>/dev/null || echo unknown)}"
TAG="${TAG:-}"

die() { echo "错误: $*" >&2; exit 1; }

PRODUCT="$(sed -n 's/^  "productName": "\(.*\)",$/\1/p' "${REPO_ROOT}/src-tauri/tauri.conf.json" | head -1)"
[ -n "$PRODUCT" ] || PRODUCT="VideoFlow"

VERSION="${VERSION:-$(sed -n 's/^  "version": "\(.*\)",$/\1/p' "${REPO_ROOT}/package.json" | head -1)}"
[ -n "$VERSION" ] || die "无法确定版本号（请设置 VERSION）"

ARCH_LABEL="${ARCH_LABEL:-aarch64}"

DMG="$(find "${BUNDLE_DIR}/dmg" -maxdepth 1 -name '*.dmg' 2>/dev/null | head -1)"
APP="${BUNDLE_DIR}/macos/${PRODUCT}.app"
[ -n "$DMG" ] && [ -f "$DMG" ] || die "找不到 DMG: ${BUNDLE_DIR}/dmg/*.dmg"
[ -d "$APP" ] || die "找不到 .app: ${APP}"

# ---------------------------------------------------------------------------
# 签名属性取自实际产物（codesign），不由 SIGNING_MODE 推断，避免清单与产物不符
# ---------------------------------------------------------------------------
app_sign="$(codesign -dv --verbose=2 "$APP" 2>&1 || true)"
SIGN_IDENTITY="$(printf '%s\n' "$app_sign" | sed -n 's/^Authority=//p' | head -1)"
[ -n "$SIGN_IDENTITY" ] || SIGN_IDENTITY="-"
SIGN_TEAM="$(printf '%s\n' "$app_sign" | sed -n 's/^TeamIdentifier=//p' | head -1)"
if printf '%s\n' "$app_sign" | grep -q 'flags=0x10000'; then HARDENED=true; else HARDENED=false; fi
if codesign --verify --strict "$DMG" >/dev/null 2>&1; then DMG_SIGNED=true; else DMG_SIGNED=false; fi

if [ "$REQUIRE_NOTARIZATION" = "true" ] && [ "$INTERNAL_BUILD" = "true" ]; then
  die "INTERNAL_BUILD 与 REQUIRE_NOTARIZATION=true 互斥：内部测试包不得被当作公证产物"
fi
if [ "$REQUIRE_NOTARIZATION" = "true" ] && [ "$TEST_RELEASE" = "true" ]; then
  die "TEST_RELEASE 与 REQUIRE_NOTARIZATION=true 互斥：测试发行不要求公证"
fi
if [ "$INTERNAL_BUILD" = "true" ] && [ "$TEST_RELEASE" = "true" ]; then
  die "TEST_RELEASE 与 INTERNAL_BUILD 互斥：两种发布模式只能选一种"
fi
if [ "$TEST_RELEASE" = "true" ]; then
  # 测试发行必须是真未签名：否则“unsigned”声明就是假的，且改写 DMG 写标记也会破坏签名
  [ "$SIGNING_MODE" = "unsigned" ] || die "TEST_RELEASE 只能用于未签名产物，当前 SIGNING_MODE=${SIGNING_MODE}"
  [ "$DMG_SIGNED" = "false" ] || die "TEST_RELEASE 要求 DMG 未签名，但 codesign 校验通过（dmg_signed=true）"
  # 公证结论只能来自 Apple；unsigned 测试发行永远只有 NOT_NOTARIZED 一种合法取值
  case "${NOTARIZATION_STATUS}" in
    ""|NOT_NOTARIZED) NOTARIZATION_STATUS="NOT_NOTARIZED" ;;
    *) die "TEST_RELEASE 的公证状态必须是 NOT_NOTARIZED（当前 ${NOTARIZATION_STATUS}）：未提交 Apple 公证就不可能得到 ACCEPTED" ;;
  esac
fi

echo "==> 整理发布产物"
echo "版本    : ${VERSION}"
echo "目标    : ${TRIPLE}"
echo "签名    : ${SIGNING_MODE}（身份: ${SIGN_IDENTITY}）"
echo "公证    : ${NOTARIZATION_STATUS}"
echo "构建类型: $( [ "$TEST_RELEASE" = "true" ] && echo 'TEST RELEASE - UNSIGNED - NOT NOTARIZED' || $( [ "$INTERNAL_BUILD" = "true" ] && echo 'INTERNAL TEST BUILD - NOT NOTARIZED' || echo 'release' ) )"

rm -rf "$OUT_DIR"
mkdir -p "$OUT_DIR"

if [ "$INTERNAL_BUILD" = "true" ]; then
  BUILD_TAG="INTERNAL-TEST-${COMMIT_SHA:0:7}-NOT-NOTARIZED"
else
  # 测试发行（tag 触发）不再往文件名里加标记，产物名与正式版同形：
  #   VideoFlow_<ver>_aarch64.dmg / .app.zip
  # 未签名、未公证的身份改由另外三处承载，缺一不可：
  #   1) release-manifest.json 的 build_kind / signing / notarization / distribution_notice
  #   2) GitHub Release 的 prerelease 标记与 Release Notes 声明
  #   3) DMG 卷内的 TEST_RELEASE.txt（写不进去即中止发布）
  BUILD_TAG=""
fi

if [ -n "$BUILD_TAG" ]; then
  DMG_NAME="${PRODUCT}_${VERSION}_${ARCH_LABEL}_${BUILD_TAG}.dmg"
  APP_ZIP_NAME="${PRODUCT}_${VERSION}_${ARCH_LABEL}_${BUILD_TAG}.app.zip"
else
  DMG_NAME="${PRODUCT}_${VERSION}_${ARCH_LABEL}.dmg"
  APP_ZIP_NAME="${PRODUCT}_${VERSION}_${ARCH_LABEL}.app.zip"
fi

cp "$DMG" "${OUT_DIR}/${DMG_NAME}"
# 用 ditto 打包 .app：保留符号链接、扩展属性与签名信息（zip 命令会破坏签名）
ditto -c -k --sequesterRsrc --keepParent "$APP" "${OUT_DIR}/${APP_ZIP_NAME}"
echo "已归档: ${DMG_NAME} / ${APP_ZIP_NAME}"

# 往 DMG 卷内写一份说明文件（内部构建 / 测试发行共用）。
# 做法：转成读写镜像 → 拷入文件 → 压回 UDZO。成功返回 0，并已重新 verify。
# 注意：改写后的 DMG 是新的字节，因此 SHA256SUMS 必须在这之后生成。
embed_dmg_notice() { # $1=DMG 路径  $2=卷内文件名  $3=源文件
  local dmg="$1" inner="$2" src="$3"
  local rw_base="${OUT_DIR}/.notice-rw" final_base="${OUT_DIR}/.notice-final" mnt="${OUT_DIR}/.notice-mnt"
  local ok=false
  if hdiutil convert "$dmg" -format UDRW -ov -o "$rw_base" >/dev/null 2>&1 \
     && mkdir -p "$mnt" \
     && hdiutil attach "${rw_base}.dmg" -readwrite -nobrowse -mountpoint "$mnt" >/dev/null 2>&1; then
    cp "$src" "${mnt}/${inner}" 2>/dev/null || true
    sync
    hdiutil detach "$mnt" -quiet >/dev/null 2>&1 || hdiutil detach "$mnt" -force -quiet >/dev/null 2>&1 || true
    if hdiutil convert "${rw_base}.dmg" -format UDZO -ov -o "$final_base" >/dev/null 2>&1 && [ -f "${final_base}.dmg" ]; then
      mv -f "${final_base}.dmg" "$dmg"
      hdiutil verify "$dmg" >/dev/null 2>&1 && ok=true
    fi
  fi
  rm -rf "${rw_base}.dmg" "${final_base}.dmg" "$mnt"
  [ "$ok" = "true" ]
}

# 内部测试包：除了文件名，还把标记写进 DMG 内部与打包目录，避免被当成正式版
dmg_inner_marker=false
if [ "$INTERNAL_BUILD" = "true" ]; then
  cat > "${OUT_DIR}/INTERNAL_TEST_BUILD.txt" <<EOF
INTERNAL TEST BUILD - NOT NOTARIZED

product : ${PRODUCT}
version : ${VERSION}
commit  : ${COMMIT_SHA}
built   : $(date -u +%Y-%m-%dT%H:%M:%SZ)
signing : ${SIGNING_MODE}
notarize: ${NOTARIZATION_STATUS}

This build is for internal installation and runtime verification only. It is not a
release artifact and must not be distributed externally.
It has no Developer ID signature and was not notarized by Apple; Gatekeeper will block it.
EOF
  if embed_dmg_notice "${OUT_DIR}/${DMG_NAME}" "INTERNAL_TEST_BUILD.txt" "${OUT_DIR}/INTERNAL_TEST_BUILD.txt"; then
    dmg_inner_marker=true
  fi
  echo "DMG 内标记: ${dmg_inner_marker}"
  # 标记已经写进 DMG；留在发布目录里会让 SHA256SUMS 指向一个用户下载不到的文件
  if [ "${dmg_inner_marker}" = "true" ]; then rm -f "${OUT_DIR}/INTERNAL_TEST_BUILD.txt"; fi
fi

# tag 测试发行：DMG 内必须有 TEST_RELEASE.txt，写不进去就不允许发布
if [ "$TEST_RELEASE" = "true" ]; then
  cat > "${OUT_DIR}/TEST_RELEASE.txt" <<EOF
TEST RELEASE - UNSIGNED - NOT NOTARIZED

product : ${PRODUCT}
version : ${VERSION}
commit  : ${COMMIT_SHA}
tag     : ${TAG:-(not a tag build)}
built   : $(date -u +%Y-%m-%dT%H:%M:%SZ)
signing : unsigned (no Developer ID signature)
notarize: NOT_NOTARIZED (not submitted to Apple, no ticket)

This is a test release: it has no Developer ID signature and was not notarized by Apple.
macOS Gatekeeper may block it or warn that the developer cannot be verified; open it only
after confirming the download came from a trusted source.
This build is not proof of Apple notarization or full Gatekeeper acceptance, and it is not
a stable release.
EOF
  if embed_dmg_notice "${OUT_DIR}/${DMG_NAME}" "TEST_RELEASE.txt" "${OUT_DIR}/TEST_RELEASE.txt"; then
    dmg_inner_marker=true
  else
    die "无法把 TEST_RELEASE.txt 写进 DMG，测试发行中止（不能发布没有标识的包）"
  fi
  echo "DMG 内标记: ${dmg_inner_marker}"
  # 标记已经写进 DMG；留在发布目录里会让 SHA256SUMS 包含一个用户下载不到的文件，
  # 那样用户跑 shasum -c 会报 “TEST_RELEASE.txt: No such file or directory”。
  rm -f "${OUT_DIR}/TEST_RELEASE.txt"
fi

# 装订票据必须随复制后的制品一起存在（不能只看 bundle 里的原件）
if xcrun stapler validate "${OUT_DIR}/${DMG_NAME}" >/dev/null 2>&1; then
  TICKET_DMG=true
else
  TICKET_DMG=false
  if [ "$REQUIRE_NOTARIZATION" = "true" ]; then
    die "复制后的 DMG 丢失公证票据（stapler validate 失败），不得发布"
  fi
fi
if xcrun stapler validate "$APP" >/dev/null 2>&1; then TICKET_APP=true; else TICKET_APP=false; fi
echo "票据    : dmg=${TICKET_DMG} app=${TICKET_APP}"

# 许可证随发布页可见，避免用户必须先装 App 才能读到要约
cp "${REPO_ROOT}/docs/THIRD_PARTY_LICENSES.md" "${OUT_DIR}/THIRD_PARTY_LICENSES.md"
cp "${REPO_ROOT}/licenses/SOURCE_OFFER.txt" "${OUT_DIR}/SOURCE_OFFER.txt"

# ---------------------------------------------------------------------------
# 引擎信息：取自 .app 内的 sidecar，确保与随包分发的就是同一份
# ---------------------------------------------------------------------------
sidecar_sha() { shasum -a 256 "$1" | cut -d' ' -f1; }
YDL="${APP}/Contents/MacOS/yt-dlp"
FFM="${APP}/Contents/MacOS/ffmpeg"
FFP="${APP}/Contents/MacOS/ffprobe"
for f in "$YDL" "$FFM" "$FFP"; do
  [ -f "$f" ] || die "App 内缺少 sidecar: $f"
done
YDL_VERSION="$("$YDL" --version 2>/dev/null | head -1)"
FFM_VERSION="$("$FFM" -hide_banner -version 2>/dev/null | sed -n 's/^ffmpeg version \([^ ]*\).*/\1/p' | head -1)"
FFP_VERSION="$("$FFP" -hide_banner -version 2>/dev/null | sed -n 's/^ffprobe version \([^ ]*\).*/\1/p' | head -1)"

dmg_sha="$(sidecar_sha "${OUT_DIR}/${DMG_NAME}")"
zip_sha="$(sidecar_sha "${OUT_DIR}/${APP_ZIP_NAME}")"
dmg_size="$(stat -f%z "${OUT_DIR}/${DMG_NAME}")"
zip_size="$(stat -f%z "${OUT_DIR}/${APP_ZIP_NAME}")"

if [ "$TEST_RELEASE" = "true" ]; then
  BUILD_KIND="test-release"
  SIGN_DESC="TEST RELEASE - UNSIGNED - NOT NOTARIZED"
  DISTRIBUTION_NOTICE="TEST RELEASE - UNSIGNED - NOT NOTARIZED"
elif [ "$INTERNAL_BUILD" = "true" ]; then
  BUILD_KIND="internal-test"
  SIGN_DESC="INTERNAL TEST BUILD - NOT NOTARIZED"
  DISTRIBUTION_NOTICE="INTERNAL TEST BUILD - NOT NOTARIZED"
elif [ "$SIGNING_MODE" = "developer-id" ]; then
  BUILD_KIND="release"
  DISTRIBUTION_NOTICE=""
  if [ "$NOTARIZATION_STATUS" = "ACCEPTED" ] && [ "$TICKET_DMG" = "true" ]; then
    SIGN_DESC="Signed with Developer ID, Notarized and Stapled"
  else
    SIGN_DESC="Signed with Developer ID, Not Notarized"
  fi
else
  BUILD_KIND="release"
  DISTRIBUTION_NOTICE=""
  SIGN_DESC="Unsigned (internal testing only)"
fi

# 清单里“没有签名身份”应当写成 null，而不是一个看起来像名字的 "-"
if [ "$TEST_RELEASE" = "true" ]; then
  SIGN_IDENTITY_JSON="null"
  SIGN_TEAM_JSON="null"
  NOTARY_METHOD="none"
  NOTARY_TOOL="none"
else
  SIGN_IDENTITY_JSON="\"${SIGN_IDENTITY}\""
  SIGN_TEAM_JSON="\"${SIGN_TEAM}\""
  NOTARY_METHOD="app-store-connect-team-api-key"
  NOTARY_TOOL="xcrun notarytool"
fi

cat > "${OUT_DIR}/release-manifest.json" <<EOF
{
  "product": "${PRODUCT}",
  "version": "${VERSION}",
  "tag": "${TAG}",
  "commit": "${COMMIT_SHA}",
  "target": "${TRIPLE}",
  "packaged_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "build_kind": "${BUILD_KIND}",
  "distribution_notice": "${DISTRIBUTION_NOTICE}",
  "dmg_inner_marker": ${dmg_inner_marker},
  "signing": {
    "mode": "${SIGNING_MODE}",
    "identity": ${SIGN_IDENTITY_JSON},
    "team_id": ${SIGN_TEAM_JSON},
    "description": "${SIGN_DESC}",
    "hardened_runtime": ${HARDENED},
    "dmg_signed": ${DMG_SIGNED}
  },
  "notarization": {
    "method": "${NOTARY_METHOD}",
    "tool": "${NOTARY_TOOL}",
    "status": "${NOTARIZATION_STATUS}",
    "submission_id": "${NOTARIZATION_SUBMISSION_ID}",
    "required": ${REQUIRE_NOTARIZATION},
    "ticket_stapled": { "dmg": ${TICKET_DMG}, "app": ${TICKET_APP} }
  },
  "engines": {
    "yt-dlp": { "version": "${YDL_VERSION}", "sha256": "$(sidecar_sha "$YDL")" },
    "ffmpeg": { "version": "${FFM_VERSION}", "sha256": "$(sidecar_sha "$FFM")" },
    "ffprobe": { "version": "${FFP_VERSION}", "sha256": "$(sidecar_sha "$FFP")" }
  },
  "licenses": {
    "third_party": "THIRD_PARTY_LICENSES.md",
    "source_offer": "SOURCE_OFFER.txt",
    "ffmpeg_license": "LGPL-2.1-or-later"
  },
  "artifacts": [
    { "file": "${DMG_NAME}", "sha256": "${dmg_sha}", "size": ${dmg_size} },
    { "file": "${APP_ZIP_NAME}", "sha256": "${zip_sha}", "size": ${zip_size} }
  ]
}
EOF

"${REPO_ROOT}/scripts/generate-checksums.sh" "$OUT_DIR" >/dev/null

echo
echo "发布目录: ${OUT_DIR}"
ls -lh "$OUT_DIR" | tail -n +2 | awk '{print "  "$9"  "$5}'
echo
echo "引擎版本: yt-dlp ${YDL_VERSION} / ffmpeg ${FFM_VERSION} / ffprobe ${FFP_VERSION}"
echo "下一步: BUNDLE_DIR=${BUNDLE_DIR} SIGNING_MODE=${SIGNING_MODE} ./scripts/verify-release.sh"
