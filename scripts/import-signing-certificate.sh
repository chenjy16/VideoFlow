#!/usr/bin/env bash
# Developer ID 证书导入 / 清理（只在 CI 的 developer-id 模式下使用）。
#
# 用法：
#   ./scripts/import-signing-certificate.sh            导入到临时 keychain
#   ./scripts/import-signing-certificate.sh --cleanup  删除临时 keychain 并复原搜索列表
#
# 输入环境变量（全部来自 GitHub Secrets）：
#   APPLE_CERTIFICATE           base64 编码的 .p12 证书（允许含换行）
#   APPLE_CERTIFICATE_PASSWORD  .p12 的导出密码
#   APPLE_SIGNING_IDENTITY      期望的签名身份全名，例如
#                               "Developer ID Application: jianyu chen (HQC33J8U5Y)"
#
# 设计约束：
#   * 凭据只从环境变量读入，任何分支都不 echo 凭据；脚本内禁止 set -x
#   * p12 只在 $RUNNER_TEMP 下存在，导入后立刻覆写擦除
#   * keychain 密码随机生成，只写 0600 文件，不进 GITHUB_ENV（避免日志回显）
#   * 导入成功后回填 APPLE_SIGNING_IDENTITY / VIDEOFLOW_TEAM_ID，供后续校验断言
set -euo pipefail

RUNNER_TEMP="${RUNNER_TEMP:-/tmp}"
KEYCHAIN_PATH="${KEYCHAIN_PATH:-${RUNNER_TEMP}/videoflow-signing.keychain-db}"
PASSWORD_FILE="${PASSWORD_FILE:-${RUNNER_TEMP}/videoflow-keychain-password}"

info() { echo "[signing] $*"; }
die() { echo "[signing] 错误: $*" >&2; exit 1; }

# 从用户搜索列表里摘掉自己的 keychain，其余原样保留
detach_from_search_list() {
  local remaining=() kc
  while IFS= read -r kc; do
    kc="$(printf '%s' "$kc" | tr -d '",' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
    [ -n "$kc" ] || continue
    [ "$kc" = "$KEYCHAIN_PATH" ] || remaining+=("$kc")
  done < <(security list-keychains -d user)
  if [ "${#remaining[@]}" -gt 0 ]; then
    security list-keychains -d user -s "${remaining[@]}" >/dev/null
  fi
  info "已从 keychain 搜索列表移除临时条目"
}

# ---------------------------------------------------------------------------
# 清理模式
# ---------------------------------------------------------------------------
if [ "${1:-}" = "--cleanup" ]; then
  detach_from_search_list
  security delete-keychain "$KEYCHAIN_PATH" >/dev/null 2>&1 || true
  rm -f "$PASSWORD_FILE"
  info "临时 keychain 与密码文件已清理"
  exit 0
fi

# ---------------------------------------------------------------------------
# 导入模式
# ---------------------------------------------------------------------------
[ -n "${APPLE_CERTIFICATE:-}" ] || die "必须设置 APPLE_CERTIFICATE（base64 编码的 .p12）"
[ -n "${APPLE_CERTIFICATE_PASSWORD:-}" ] || die "必须设置 APPLE_CERTIFICATE_PASSWORD"
[ -n "${APPLE_SIGNING_IDENTITY:-}" ] || die "必须设置 APPLE_SIGNING_IDENTITY"

umask 077
P12="${RUNNER_TEMP}/videoflow-cert.p12"
trap 'rm -f "$P12"' EXIT

# 允许重复运行：先清掉可能残留的同名 keychain
security delete-keychain "$KEYCHAIN_PATH" >/dev/null 2>&1 || true

KEYCHAIN_PASSWORD="$(openssl rand -hex 24)"
printf '%s' "$KEYCHAIN_PASSWORD" > "$PASSWORD_FILE"
chmod 600 "$PASSWORD_FILE"

security create-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN_PATH"
security set-keychain-settings -lut 21600 "$KEYCHAIN_PATH"
security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN_PATH"

# 解码证书：先去掉 secret 里可能存在的换行（openssl base64 -A 输出本无换行，
# 但 GitHub Secrets 的多行输入会带上）
printf '%s' "$APPLE_CERTIFICATE" | tr -d '\r\n' | base64 --decode > "$P12"
[ -s "$P12" ] || die "APPLE_CERTIFICATE 解码后为空（应为 base64 编码的 .p12）"

# 先自己解析一次：把"密码错"和"不是 p12"区分开，避免 security 的模糊报错。
# 需要试两种模式：macOS 能用的 legacy p12（RC2/3DES）在 OpenSSL 3+ 下必须加 -legacy，
# 而现代 AES p12 反而可能不认 -legacy，所以两种都试，都不行才算失败。
probe_p12() {
  openssl pkcs12 -in "$P12" -noout "$@" -passin "pass:${APPLE_CERTIFICATE_PASSWORD}" >/dev/null 2>&1
}
if ! probe_p12 -legacy && ! probe_p12; then
  die "无法解析 .p12：密码错误，或 APPLE_CERTIFICATE 不是 PKCS#12（请从 Keychain 导出为 .p12 再 base64）"
fi

# openssl 能读不等于 Security 框架能读：macOS 的 SecKeychainItemImport 只支持
# 传统 PBE（RC2/3DES + SHA1），不认 OpenSSL 3+ 默认导出的 AES-256/SHA-256。
if ! security import "$P12" -k "$KEYCHAIN_PATH" -P "$APPLE_CERTIFICATE_PASSWORD" \
     -T /usr/bin/codesign -T /usr/bin/security >/dev/null 2>&1; then
  die "security import 失败：通常是 .p12 使用了 macOS 不支持的加密算法（OpenSSL 3+ 默认 AES-256/SHA-256）。请用 Keychain Access 导出 .p12，或加 -legacy 重新导出"
fi
# -S 允许 codesign / 系统工具访问私钥；-s 只匹配可签名的键。必须显式把 keychain
# 加入搜索列表，否则 codesign 找不到身份。
if ! security set-key-partition-list -S apple-tool:,apple:,codesign: -s \
     -k "$KEYCHAIN_PASSWORD" "$KEYCHAIN_PATH" >/dev/null 2>&1; then
  die "设置私钥 partition list 失败，codesign 将无法在无人工确认的情况下使用该私钥"
fi
existing_keychains=()
while IFS= read -r kc; do
  kc="$(printf '%s' "$kc" | tr -d '",' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
  [ -n "$kc" ] || continue
  [ "$kc" = "$KEYCHAIN_PATH" ] || existing_keychains+=("$kc")
done < <(security list-keychains -d user)
if [ "${#existing_keychains[@]}" -gt 0 ]; then
  security list-keychains -d user -s "$KEYCHAIN_PATH" "${existing_keychains[@]}" >/dev/null
else
  security list-keychains -d user -s "$KEYCHAIN_PATH" >/dev/null
fi
info "临时 keychain 已加入搜索列表（原有条目保留）"

# 擦除明文 p12（超出文件长度部分不保证，但 RUNNER_TEMP 本身是临时的）
dd if=/dev/zero of="$P12" bs=4096 count=1 conv=notrunc >/dev/null 2>&1 || true
rm -f "$P12"

# ---------------------------------------------------------------------------
# 校验导入结果
# ---------------------------------------------------------------------------
IDENTITIES="$(security find-identity -v -p codesigning "$KEYCHAIN_PATH")"
ALL_IDENTITIES="$(security find-identity -p codesigning "$KEYCHAIN_PATH")"
info "keychain 中的可用签名身份（仅有效）："
printf '%s\n' "$IDENTITIES" | sed 's/^/[signing]   /'
info "keychain 中全部代码签名身份（含未受信任）："
printf '%s\n' "$ALL_IDENTITIES" | sed 's/^/[signing]   /'

if ! printf '%s\n' "$ALL_IDENTITIES" | grep -qF "\"${APPLE_SIGNING_IDENTITY}\""; then
  die "keychain 中找不到身份 '${APPLE_SIGNING_IDENTITY}'；APPLE_SIGNING_IDENTITY 必须与证书名称完全一致"
fi

# 存在于 keychain 但不在 -v（只有受信任身份才会出现在 -v）列表里，通常是链不完整/未受信任/已过期
if ! printf '%s\n' "$IDENTITIES" | grep -qF "\"${APPLE_SIGNING_IDENTITY}\""; then
  die "证书已导入但不是有效的代码签名身份（未受信任、已过期或缺少中间证书）；请确认导出的是完整 Developer ID Application 证书（含中间证书）"
fi

if ! printf '%s\n' "$ALL_IDENTITIES" | grep -qF 'Developer ID Application'; then
  die "导入的证书不是 Developer ID Application 类型，不能用于分发签名"
fi

# 从 "... (TEAMID)" 里取 Team ID（只取目标身份所在行），用于校 .app 与 .dmg 的签名归属一致
TEAM_ID="$(printf '%s\n%s\n' "$IDENTITIES" "$ALL_IDENTITIES" | grep -F "\"${APPLE_SIGNING_IDENTITY}\"" | sed -n 's/.*(\([A-Z0-9]*\))".*/\1/p' | head -1)"

info "身份校验通过: ${APPLE_SIGNING_IDENTITY}"
info "Team ID: ${TEAM_ID:-<未解析>}"

if [ -n "${GITHUB_ENV:-}" ]; then
  {
    echo "APPLE_SIGNING_IDENTITY=${APPLE_SIGNING_IDENTITY}"
    echo "VIDEOFLOW_KEYCHAIN_PATH=${KEYCHAIN_PATH}"
    echo "VIDEOFLOW_TEAM_ID=${TEAM_ID}"
  } >> "$GITHUB_ENV"
  info "已写入 GITHUB_ENV（供后续步骤与清理步骤使用）"
else
  info "未检测到 GITHUB_ENV，跳过环境变量回填（本地运行）"
fi
