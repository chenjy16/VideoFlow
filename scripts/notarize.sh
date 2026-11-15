#!/usr/bin/env bash
# 用 App Store Connect **Team API Key** 执行 Apple 公证（notarytool submit → staple → validate）。
#
# 设计原则：公证状态一律取自 Apple 的真实返回，本脚本不产生任何"假定成功"的结论。
#   凭据齐全 → 提交 → 按 Apple 返回的 status 分支 → 只有 Accepted 才 staple/validate
#   凭据缺失 + REQUIRE_NOTARIZATION=true → 状态 BLOCKED 并失败（绝不跳过公证继续发布）
#   被拒绝/失败 → 保留 submission ID、Apple 日志、失败原因，并失败
#
# 环境变量：
#   BUNDLE_DIR              默认 src-tauri/target/<triple>/release/bundle
#   TRIPLE                  默认 aarch64-apple-darwin
#   REQUIRE_NOTARIZATION    true | false（缺省 false）
#   APPLE_API_KEY           Key ID（Team API Key）
#   APPLE_API_ISSUER        Issuer ID（UUID；Team Key 必填，Individual Key 不能用）
#   APPLE_API_KEY_P8_BASE64 .p8 私钥的 base64（CI 用，解码到 $RUNNER_TEMP 后用完即删）
#   APPLE_API_KEY_PATH      已存在的 .p8 路径（本地用，与上面二选一）
#   NOTARIZATION_REPORT     默认 notarization-report.json
#   NOTARY_LOG_DIR          默认 notarization-logs
#   NOTARY_WAIT_TIMEOUT     notarytool --timeout，默认 30m
#   STAPLE_APP              1 时同时 staple .app（默认 1）
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TRIPLE="${TRIPLE:-aarch64-apple-darwin}"
BUNDLE_DIR="${BUNDLE_DIR:-${REPO_ROOT}/src-tauri/target/${TRIPLE}/release/bundle}"
REQUIRE_NOTARIZATION="${REQUIRE_NOTARIZATION:-false}"
KEY_ID="${APPLE_API_KEY:-}"
ISSUER="${APPLE_API_ISSUER:-}"
P8_B64="${APPLE_API_KEY_P8_BASE64:-}"
P8_PATH="${APPLE_API_KEY_PATH:-}"
REPORT_PATH="${NOTARIZATION_REPORT:-${REPO_ROOT}/notarization-report.json}"
LOG_DIR="${NOTARY_LOG_DIR:-${REPO_ROOT}/notarization-logs}"
WAIT_TIMEOUT="${NOTARY_WAIT_TIMEOUT:-30m}"
STAPLE_APP="${STAPLE_APP:-1}"
RUNNER_TEMP="${RUNNER_TEMP:-/tmp}"

PRODUCT="$(sed -n 's/^  "productName": "\(.*\)",$/\1/p' "${REPO_ROOT}/src-tauri/tauri.conf.json" | head -1)"
[ -n "$PRODUCT" ] || PRODUCT="VideoFlow"

note() { echo "[notarize] $*"; }
die() { echo "[notarize] 错误: $*" >&2; exit 1; }

# 报告字段（由 write_report 落盘为 JSON）
R_STATUS=""
R_APPLE_STATUS=""
R_SUBMISSION_ID=""
R_SUBMITTED_AT=""
R_COMPLETED_AT=""
R_MESSAGE=""
R_LOG_PATH=""
R_STAPLE_DMG="false"
R_STAPLE_APP="false"
R_VALIDATE_DMG="false"
R_VALIDATE_APP="false"

command -v python3 >/dev/null 2>&1 || die "需要 python3 生成 JSON 报告"

write_report() {
  local dmg_name="${1:-}"
  NTF_STATUS="$R_STATUS" \
  NTF_APPLE_STATUS="$R_APPLE_STATUS" \
  NTF_SUBMISSION_ID="$R_SUBMISSION_ID" \
  NTF_SUBMITTED_AT="$R_SUBMITTED_AT" \
  NTF_COMPLETED_AT="$R_COMPLETED_AT" \
  NTF_MESSAGE="$R_MESSAGE" \
  NTF_LOG_PATH="$R_LOG_PATH" \
  NTF_DMG="$dmg_name" \
  NTF_STAPLE_DMG="$R_STAPLE_DMG" \
  NTF_STAPLE_APP="$R_STAPLE_APP" \
  NTF_VALIDATE_DMG="$R_VALIDATE_DMG" \
  NTF_VALIDATE_APP="$R_VALIDATE_APP" \
  NTF_REQUIRED="$REQUIRE_NOTARIZATION" \
  python3 - "$REPORT_PATH" <<'PY'
import json, os, sys
env = os.environ
report = {
    "tool": "xcrun notarytool",
    "auth": "app-store-connect-team-api-key",
    "require_notarization": env.get("NTF_REQUIRED", "false") == "true",
    "status": env.get("NTF_STATUS", ""),
    "apple_status": env.get("NTF_APPLE_STATUS", ""),
    "submission_id": env.get("NTF_SUBMISSION_ID", ""),
    "submitted_at": env.get("NTF_SUBMITTED_AT", ""),
    "completed_at": env.get("NTF_COMPLETED_AT", ""),
    "artifact": env.get("NTF_DMG", ""),
    "message": env.get("NTF_MESSAGE", ""),
    "apple_log": env.get("NTF_LOG_PATH", ""),
    "staple": {
        "dmg": env.get("NTF_STAPLE_DMG") == "true",
        "app": env.get("NTF_STAPLE_APP") == "true",
    },
    "stapler_validate": {
        "dmg": env.get("NTF_VALIDATE_DMG") == "true",
        "app": env.get("NTF_VALIDATE_APP") == "true",
    },
    "recorded_at": __import__("datetime").datetime.now(__import__("datetime").timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
}
with open(sys.argv[1], "w") as f:
    json.dump(report, f, indent=2, ensure_ascii=False)
    f.write("\n")
PY
  [ -f "$REPORT_PATH" ] || die "无法写入公证报告: $REPORT_PATH"
}

# 凭据存在但无效/执行失败：同样要落盘真实状态，不能静默退出
fail_report() {
  R_STATUS="$1"
  R_MESSAGE="$2"
  write_report "${DMG_NAME:-}"
  export_status_env
  note "状态: ${R_STATUS}"
  note "${R_MESSAGE}"
  if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
    {
      echo "### 公证：${R_STATUS}"
      echo ""
      echo "| 项目 | 值 |"
      echo "| --- | --- |"
      echo "| 状态 | **${R_STATUS}** |"
      echo "| Apple 状态 | ${R_APPLE_STATUS:-—} |"
      echo "| Submission ID | ${R_SUBMISSION_ID:-—} |"
      echo "| 原因 | ${R_MESSAGE} |"
      echo "| Apple 日志 | ${R_LOG_PATH:-—} |"
    } >> "$GITHUB_STEP_SUMMARY"
  fi
  exit 1
}

# 把真实状态回填给后续步骤（package-release / 汇总 / release job 都读这个值）
export_status_env() {
  if [ -n "${GITHUB_ENV:-}" ]; then
    {
      echo "NOTARIZATION_STATUS=${R_STATUS}"
      echo "NOTARIZATION_SUBMISSION_ID=${R_SUBMISSION_ID}"
    } >> "$GITHUB_ENV"
  fi
}

DMG="$(find "${BUNDLE_DIR}/dmg" -maxdepth 1 -name '*.dmg' 2>/dev/null | head -1)"
APP="${BUNDLE_DIR}/macos/${PRODUCT}.app"
DMG_NAME=""
[ -n "$DMG" ] && [ -f "$DMG" ] && DMG_NAME="$(basename "$DMG")"

echo "== 公证流程 =="
echo "目标  : ${DMG:-<未找到 DMG>}"
echo ".app  : ${APP}"
echo "要求  : REQUIRE_NOTARIZATION=${REQUIRE_NOTARIZATION}"
echo "认证  : App Store Connect Team API Key（Key ID $([ -n "$KEY_ID" ] && echo '已提供' || echo '未提供')）"
echo

# ---------------------------------------------------------------------------
# 1. 凭据判定：缺失一律 BLOCKED，绝不"跳过公证继续发布"
# ---------------------------------------------------------------------------
missing=()
[ -n "$KEY_ID" ] || missing+=("APPLE_API_KEY（Key ID）")
[ -n "$ISSUER" ] || missing+=("APPLE_API_ISSUER（Issuer ID）")
if [ -z "$P8_B64" ] && [ -z "$P8_PATH" ]; then
  missing+=("APPLE_API_KEY_P8_BASE64（.p8 私钥 base64）")
fi

if [ "${#missing[@]}" -gt 0 ]; then
  R_MESSAGE="缺少公证凭据：$(printf '%s; ' "${missing[@]}")"
  if [ "$REQUIRE_NOTARIZATION" = "true" ]; then
    R_STATUS="BLOCKED"
    write_report "$DMG_NAME"
    export_status_env
    note "状态: BLOCKED"
    note "$R_MESSAGE"
    note "REQUIRE_NOTARIZATION=true，未公证的产物不得发布。"
    if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
      {
        echo "### 公证：BLOCKED"
        echo ""
        echo "| 项目 | 值 |"
        echo "| --- | --- |"
        echo "| 状态 | **BLOCKED** |"
        echo "| 原因 | ${R_MESSAGE} |"
        echo "| 后续动作 | 配置 Secrets 后重跑；未公证产物不进入发布 |"
      } >> "$GITHUB_STEP_SUMMARY"
    fi
    exit 1
  fi
  R_STATUS="NOT_NOTARIZED"
  write_report "$DMG_NAME"
  export_status_env
  note "状态: NOT_NOTARIZED（REQUIRE_NOTARIZATION=false，本轮不公证）"
  exit 0
fi

[ -n "$DMG" ] && [ -f "$DMG" ] || fail_report "FAILED" "找不到待公证的 DMG: ${BUNDLE_DIR}/dmg/*.dmg"

# ---------------------------------------------------------------------------
# 2. 准备私钥：解码到 $RUNNER_TEMP，权限 600，全程不进日志/产物/仓库
# ---------------------------------------------------------------------------
cleanup_key() {
  if [ -n "${TMP_P8:-}" ] && [ -f "$TMP_P8" ]; then
    dd if=/dev/zero of="$TMP_P8" bs=4096 count=1 conv=notrunc >/dev/null 2>&1 || true
    rm -f "$TMP_P8"
  fi
}
trap cleanup_key EXIT INT TERM

umask 077
if [ -n "$P8_B64" ]; then
  TMP_P8="${RUNNER_TEMP}/AuthKey_${KEY_ID}.p8"
  printf '%s' "$P8_B64" | tr -d '\r\n' | base64 --decode > "$TMP_P8"
  [ -s "$TMP_P8" ] || die "APPLE_API_KEY_P8_BASE64 解码后为空"
  chmod 600 "$TMP_P8"
  P8_PATH="$TMP_P8"
  note "私钥已解码到 \$RUNNER_TEMP（权限 600，用完即删）"
fi

[ -f "$P8_PATH" ] || fail_report "FAILED" "找不到 .p8 私钥文件"
if ! openssl pkey -in "$P8_PATH" -noout >/dev/null 2>&1; then
  fail_report "FAILED" ".p8 不是有效的私钥（应为 App Store Connect 下载的 AuthKey_<KEYID>.p8）"
fi

if ! printf '%s' "$KEY_ID" | grep -Eq '^[A-Za-z0-9]{10,}$'; then
  fail_report "FAILED" "APPLE_API_KEY 格式异常（应为 10 位以上字母数字）"
fi
if ! printf '%s' "$ISSUER" | grep -Eq '^[0-9a-fA-F-]{36}$'; then
  fail_report "FAILED" "APPLE_API_ISSUER 格式异常（应为 UUID；Individual API Key 没有 Issuer，本项目只支持 Team Key）"
fi

mkdir -p "$LOG_DIR"

# ---------------------------------------------------------------------------
# 3. 提交公证并等待结果
# ---------------------------------------------------------------------------
R_SUBMITTED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
SUBMIT_JSON="${LOG_DIR}/submit-$(date -u +%Y%m%dT%H%M%SZ).json"
SUBMIT_ERR="${LOG_DIR}/submit.stderr"

note "提交公证：$(basename "$DMG")"
xcrun notarytool submit "$DMG" \
  --key "$P8_PATH" --key-id "$KEY_ID" --issuer "$ISSUER" \
  --wait --timeout "$WAIT_TIMEOUT" --output-format json \
  > "$SUBMIT_JSON" 2> "$SUBMIT_ERR"
submit_rc=$?
R_COMPLETED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

# 从 Apple 返回的 JSON 里取 id / status —— 不猜、不写死
read -r R_SUBMISSION_ID R_APPLE_STATUS <<EOF
$(python3 - "$SUBMIT_JSON" <<'PY'
import json, sys
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    print("\t")
    sys.exit(0)
print("%s\t%s" % (d.get("id", ""), d.get("status", "")))
PY
)
EOF

if [ -z "$R_SUBMISSION_ID" ]; then
  R_MESSAGE="notarytool submit 未返回 submission id（exit=${submit_rc}）；$(tail -n 3 "$SUBMIT_ERR" 2>/dev/null | tr '\n' ' ')"
  case "$R_MESSAGE" in
    *ndividual*|*Individual*)
      R_MESSAGE="${R_MESSAGE} —— 本项目要求 Team API Key；Individual Key 没有 Issuer，不能用于 notarytool" ;;
    *401*|*Unauthenticated*)
      R_MESSAGE="${R_MESSAGE} —— 请确认 Key ID / Issuer ID / .p8 三者配套，且必须是 Team API Key（Individual Key 无法配合 --issuer 使用）" ;;
  esac
  fail_report "FAILED" "$R_MESSAGE"
fi

note "Submission ID: ${R_SUBMISSION_ID}"
note "Apple 返回状态: ${R_APPLE_STATUS:-<空>}"

if [ "$R_APPLE_STATUS" != "Accepted" ]; then
  # 保留 Apple 日志与失败原因（requirement 11）
  R_LOG_PATH="${LOG_DIR}/notarytool-${R_SUBMISSION_ID}.json"
  xcrun notarytool log "$R_SUBMISSION_ID" "$R_LOG_PATH" \
    --key "$P8_PATH" --key-id "$KEY_ID" --issuer "$ISSUER" >/dev/null 2>&1 \
    || R_LOG_PATH=""
  R_STATUS="$(printf '%s' "${R_APPLE_STATUS:-FAILED}" | tr '[:lower:]' '[:upper:]')"
  R_MESSAGE="Apple 返回 ${R_APPLE_STATUS:-未知状态}，未执行 staple，产物不得发布"
  if [ -n "$R_LOG_PATH" ] && [ -f "$R_LOG_PATH" ]; then
    R_MESSAGE="${R_MESSAGE}（Apple 日志：${R_LOG_PATH}）"
  fi
  fail_report "$R_STATUS" "$R_MESSAGE"
fi

# ---------------------------------------------------------------------------
# 4. 只有 Accepted 才 staple（Apple 要求先拿到 Accepted 票据）
# ---------------------------------------------------------------------------
R_STATUS="ACCEPTED"

if xcrun stapler staple "$DMG" -q; then
  note "已 staple: $(basename "$DMG")"
else
  fail_report "STAPLE_FAILED" "已获得 Accepted，但 stapler staple 失败（DMG）"
fi
if xcrun stapler validate "$DMG" -q; then
  R_STAPLE_DMG="true"; R_VALIDATE_DMG="true"
  note "stapler validate 通过: $(basename "$DMG")"
else
  fail_report "STAPLE_FAILED" "stapler validate 未通过（DMG）"
fi

if [ "$STAPLE_APP" = "1" ]; then
  [ -d "$APP" ] || fail_report "STAPLE_FAILED" "找不到 .app，无法 staple 应用包"
  if xcrun stapler staple "$APP" -q && xcrun stapler validate "$APP" -q; then
    R_STAPLE_APP="true"; R_VALIDATE_APP="true"
    note "已 staple 并通过 validate: $(basename "$APP")"
  else
    fail_report "STAPLE_FAILED" ".app 的 staple/validate 失败（DMG 已成功）；.app.zip 不应发布"
  fi
fi

R_MESSAGE="Apple 返回 Accepted；staple 与 validate 均已通过"
write_report "$DMG_NAME"
export_status_env

note "状态: ACCEPTED（Apple 真实返回）"
note "提示：SHA256SUMS 必须在 staple 之后重新生成（由 package-release.sh 负责）"
