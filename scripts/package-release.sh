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
#   NOTARIZATION_STATUS   NOT_CONFIGURED / NOT_NOTARIZED / SUBMITTED / ACCEPTED / REJECTED
#   REQUIRE_NOTARIZATION  默认 false
#   BUNDLE_DIR            默认 src-tauri/target/<triple>/release/bundle
#   OUT_DIR               默认 dist-release
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TRIPLE="${TRIPLE:-aarch64-apple-darwin}"
OUT_DIR="${OUT_DIR:-${REPO_ROOT}/dist-release}"
BUNDLE_DIR="${BUNDLE_DIR:-${REPO_ROOT}/src-tauri/target/${TRIPLE}/release/bundle}"
SIGNING_MODE="${SIGNING_MODE:-unsigned}"
NOTARIZATION_STATUS="${NOTARIZATION_STATUS:-NOT_NOTARIZED}"
REQUIRE_NOTARIZATION="${REQUIRE_NOTARIZATION:-false}"
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

echo "==> 整理发布产物"
echo "版本    : ${VERSION}"
echo "目标    : ${TRIPLE}"
echo "签名    : ${SIGNING_MODE}（身份: ${SIGN_IDENTITY}）"
echo "公证    : ${NOTARIZATION_STATUS}"

rm -rf "$OUT_DIR"
mkdir -p "$OUT_DIR"

DMG_NAME="${PRODUCT}_${VERSION}_${ARCH_LABEL}.dmg"
APP_ZIP_NAME="${PRODUCT}_${VERSION}_${ARCH_LABEL}.app.zip"

cp "$DMG" "${OUT_DIR}/${DMG_NAME}"
# 用 ditto 打包 .app：保留符号链接、扩展属性与签名信息（zip 命令会破坏签名）
ditto -c -k --sequesterRsrc --keepParent "$APP" "${OUT_DIR}/${APP_ZIP_NAME}"
echo "已归档: ${DMG_NAME} / ${APP_ZIP_NAME}"

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

cat > "${OUT_DIR}/release-manifest.json" <<EOF
{
  "product": "${PRODUCT}",
  "version": "${VERSION}",
  "tag": "${TAG}",
  "commit": "${COMMIT_SHA}",
  "target": "${TRIPLE}",
  "packaged_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "signing": {
    "mode": "${SIGNING_MODE}",
    "identity": "${SIGN_IDENTITY}",
    "team_id": "${SIGN_TEAM}",
    "description": "$([ "$SIGNING_MODE" = "developer-id" ] && echo "Signed with Developer ID, Not Notarized" || echo "Unsigned (internal testing only)")",
    "hardened_runtime": ${HARDENED},
    "dmg_signed": ${DMG_SIGNED}
  },
  "notarization": {
    "status": "${NOTARIZATION_STATUS}",
    "required": ${REQUIRE_NOTARIZATION}
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
