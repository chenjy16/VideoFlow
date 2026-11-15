#!/usr/bin/env bash
# 发布门禁回归测试。
#
# 直接解析 .github/workflows/release.yml 里**真实的**表达式与 run 块，而不是另抄一份规则：
#   * internal_build 绝不能触发 Release
#   * tag 发布绝不能走 unsigned 路径
#   * internal_build 与公证/签名/tag 互斥
#   * 权限划分：build 只读、release 独占 contents: write
#   * 公证脚本不得存在"没拿到 Apple Accepted 就成功"的路径
#
# 用法：./scripts/test-release-gating.sh
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WF="${REPO_ROOT}/.github/workflows/release.yml"
NOTARIZE="${REPO_ROOT}/scripts/notarize.sh"
VERIFY="${REPO_ROOT}/scripts/verify-release.sh"

PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); echo "  [PASS] $*"; }
no() { FAIL=$((FAIL + 1)); echo "  [FAIL] $*"; }
hdr() { echo; echo "=== $* ==="; }
die() { echo "错误: $*" >&2; exit 1; }

[ -f "$WF" ] || die "找不到 $WF"
[ -f "$NOTARIZE" ] || die "找不到 $NOTARIZE"
[ -f "$VERIFY" ] || die "找不到 $VERIFY"

TMP="$(mktemp -d /tmp/vf-gating.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

# ---------------------------------------------------------------------------
# 导出 workflow 结构：env 表达式、release job 的 if、关键 run 块、权限
# ---------------------------------------------------------------------------
ruby -ryaml -rjson -e '
wf = YAML.load_file(ARGV[0])
out = {}
out["env"] = wf["env"] || {}
out["workflow_permissions"] = wf["permissions"]
out["release_if"] = wf.dig("jobs", "release", "if")
out["build_permissions"] = wf.dig("jobs", "build", "permissions")
out["release_permissions"] = wf.dig("jobs", "release", "permissions")
blocks = {}
wf["jobs"].each do |job_id, job|
  (job["steps"] || []).each do |st|
    next unless st["run"] && st["id"]
    blocks["#{job_id}:#{st["id"]}"] = st["run"]
  end
end
out["blocks"] = blocks
File.write(ARGV[1], JSON.pretty_generate(out))
' "$WF" "$TMP/wf.json" || die "解析 $WF 失败"

jget_raw() { ruby -rjson -e 'd=JSON.parse(File.read(ARGV[0])); k=ARGV[1].split("."); k.each{|x| d=d[x]}; puts(d.is_a?(String) ? d : d.to_json)' "$TMP/wf.json" "$1"; }

# 用 Ruby 求值 GitHub 表达式（&&/||/==/!/真值语义与 GitHub 一致：非空字符串为真）
eval_expr() { # $1 = 表达式  $2.. = context JSON
  ruby -rjson -e '
expr, ctx_json = ARGV[0], ARGV[1]
ctx = JSON.parse(ctx_json)
gh   = (ctx["github"] || {}).transform_keys(&:to_sym)
inp  = (ctx["inputs"] || {}).transform_keys(&:to_sym)
ns   = (ctx["needs"]  || {}).transform_keys(&:to_sym)
src = expr.dup
src = src.gsub(/\$\{\{/, "").gsub(/\}\}/, "").strip
src = src.gsub(/needs\.(\w+)\.outputs\.(\w+)/) { "ns[:#{$2}]" }
src = src.gsub(/\bgithub\.(\w+)\b/) { "gh[:#{$1}]" }
src = src.gsub(/\binputs\.(\w+)\b/) { "inp[:#{$1}]" }
src = src.gsub(/\bnull\b/, "nil")
src = src.gsub(/\btrue\b/, "true").gsub(/\bfalse\b/, "false")
val = eval(src)
puts(val.is_a?(String) ? val : val.to_s)
' "$1" "$2"
}

ctx() { # $1=event $2=ref_type $3=internal_build $4=dry_run
  ruby -rjson -e '
ev, rt, ib, dry = ARGV
h = { "github" => { "event_name" => ev, "ref_type" => rt },
      "inputs" => {}, "needs" => {} }
h["inputs"]["internal_build"] = (ib == "true") if %w[true false].include?(ib)
h["inputs"]["dry_run"] = (dry == "true") if %w[true false].include?(dry)
puts JSON.generate(h)
' "$1" "$2" "$3" "$4"
}

# ---------------------------------------------------------------------------
hdr "1. 环境表达式：REQUIRE_NOTARIZATION / INTERNAL_BUILD"
REQ_EXPR="$(ruby -rjson -e 'puts JSON.parse(File.read(ARGV[0]))["env"]["REQUIRE_NOTARIZATION"]' "$TMP/wf.json")"
INT_EXPR="$(ruby -rjson -e 'puts JSON.parse(File.read(ARGV[0]))["env"]["INTERNAL_BUILD"]' "$TMP/wf.json")"
echo "  REQUIRE_NOTARIZATION = ${REQ_EXPR}"
echo "  INTERNAL_BUILD       = ${INT_EXPR}"

expect_env() { # $1=event $2=ref_type $3=internal_build $4=dry_run $5=期望 REQUIRE $6=期望 INTERNAL
  local c req int
  c="$(ctx "$1" "$2" "$3" "$4")"
  req="$(eval_expr "$REQ_EXPR" "$c")"
  int="$(eval_expr "$INT_EXPR" "$c")"
  if [ "$req" = "$5" ] && [ "$int" = "$6" ]; then
    ok "$1/$2/internal_build=$3 → REQUIRE=${req} INTERNAL=${int}"
  else
    no "$1/$2/internal_build=$3 → 期望 REQUIRE=$5 INTERNAL=$6，实际 REQUIRE=${req} INTERNAL=${int}"
  fi
}

expect_env push         tag    null   null   true  false
expect_env workflow_dispatch tag false false  true  false
expect_env workflow_dispatch branch false false true  false
expect_env workflow_dispatch branch true  true   false true
expect_env workflow_dispatch branch true  false  false true

# ---------------------------------------------------------------------------
hdr "2. release job 触发条件：internal_build 一律不发布"
RELEASE_IF="$(ruby -rjson -e 'puts JSON.parse(File.read(ARGV[0]))["release_if"]' "$TMP/wf.json")"
echo "  if: ${RELEASE_IF}"

expect_release() { # $1=event $2=ref_type $3=internal_build $4=dry_run $5=期望 true/false
  local got
  got="$(eval_expr "$RELEASE_IF" "$(ctx "$1" "$2" "$3" "$4")")"
  [ "$got" = "true" ] && got=true || got=false
  if [ "$got" = "$5" ]; then
    ok "$1/$2/internal_build=$3/dry_run=$4 → 创建 Release=${got}"
  else
    no "$1/$2/internal_build=$3/dry_run=$4 → 期望 ${5}，实际 ${got}"
  fi
}

expect_release push                tag    null  null  true
expect_release workflow_dispatch   tag    false false true
expect_release workflow_dispatch   tag    false true  false
expect_release workflow_dispatch   tag    true  false false
expect_release workflow_dispatch   tag    true  true  false
expect_release workflow_dispatch   branch false false false
expect_release workflow_dispatch   branch true  false false

# ---------------------------------------------------------------------------
hdr "3. 签名判定块：tag 不得走 unsigned"
SIGN_BLOCK="$(ruby -rjson -e 'puts JSON.parse(File.read(ARGV[0]))["blocks"]["validate:signing"]' "$TMP/wf.json")"
[ -n "$SIGN_BLOCK" ] || die "未找到 validate/signing 步骤的 run 块"
printf '%s' "$SIGN_BLOCK" > "$TMP/signing.sh"

run_signing() { # $1=ref_type $2=cert $3=pass $4=identity $5=internal_build
  ( cd "$REPO_ROOT" \
    && GITHUB_REF_TYPE="$1" GITHUB_REF_NAME=test GITHUB_SHA=0123456789abcdef \
       GITHUB_OUTPUT="$TMP/out-signing" \
       INTERNAL_BUILD="$5" \
       APPLE_CERTIFICATE="$2" APPLE_CERTIFICATE_PASSWORD="$3" APPLE_SIGNING_IDENTITY="$4" \
       bash "$TMP/signing.sh" )
}

: > "$TMP/out-signing"
if run_signing tag "" "" "" "" >/dev/null 2>&1; then
  no "tag + 0/3 Secrets 竟然通过（unsigned 会流进正式发布）"
else
  ok "tag + 0/3 Secrets → 失败"
fi

: > "$TMP/out-signing"
if run_signing tag "x" "" "" "" >/dev/null 2>&1; then
  no "tag + 1/3 Secrets 竟然通过（半配置未拦截）"
else
  ok "tag + 1/3 Secrets → 失败"
fi

: > "$TMP/out-signing"
if run_signing tag "cert" "pass" "Developer ID Application: X (TEAM123456)" "" >/dev/null 2>&1; then
  grep -qx 'mode=developer-id' "$TMP/out-signing" \
    && ok "tag + 3/3 Secrets → developer-id" \
    || no "tag + 3/3 Secrets 通过但输出 mode 不正确"
else
  no "tag + 3/3 Secrets 竟然失败"
fi

: > "$TMP/out-signing"
if run_signing branch "" "" "" "" >/dev/null 2>&1; then
  grep -qx 'mode=unsigned' "$TMP/out-signing" \
    && ok "非 tag + 0/3 Secrets → unsigned（内部构建路径仍存在）" \
    || no "非 tag + 0/3 Secrets 输出 mode 不正确"
else
  no "非 tag + 0/3 Secrets 竟然失败"
fi

# internal_build 即便配齐了签名 Secrets 也必须是 unsigned（否则内部包带签名却无公证）
: > "$TMP/out-signing"
if run_signing branch "cert" "pass" "Developer ID Application: X (TEAM123456)" true >/dev/null 2>&1; then
  grep -qx 'mode=unsigned' "$TMP/out-signing" \
    && ok "internal_build + 非 tag + 3/3 Secrets → 强制 unsigned" \
    || no "internal_build 没能强制 unsigned"
else
  no "internal_build + 非 tag + 3/3 Secrets 竟然失败"
fi

# internal_build 永远不能用于 tag 发布
: > "$TMP/out-signing"
if run_signing tag "cert" "pass" "Developer ID Application: X (TEAM123456)" true >/dev/null 2>&1; then
  no "internal_build + tag 在签名判定阶段没被拦住"
else
  ok "internal_build + tag → 失败"
fi

# ---------------------------------------------------------------------------
hdr "4. 公证凭据判定块：internal_build 与 tag / 公证互斥"
CREDS_BLOCK="$(ruby -rjson -e 'puts JSON.parse(File.read(ARGV[0]))["blocks"]["validate:notarize_creds"]' "$TMP/wf.json")"
[ -n "$CREDS_BLOCK" ] || die "未找到 validate/notarize_creds 步骤的 run 块"
printf '%s' "$CREDS_BLOCK" > "$TMP/creds.sh"

run_creds() { # $1=ref_type $2=INTERNAL_BUILD $3=REQUIRE_NOTARIZATION $4=key $5=issuer $6=p8
  ( cd "$REPO_ROOT" \
    && GITHUB_REF_TYPE="$1" GITHUB_OUTPUT="$TMP/out-creds" \
       INTERNAL_BUILD="$2" REQUIRE_NOTARIZATION="$3" \
       APPLE_API_KEY="$4" APPLE_API_ISSUER="$5" APPLE_API_KEY_P8_BASE64="$6" \
       bash "$TMP/creds.sh" )
}

: > "$TMP/out-creds"
if run_creds tag true false "" "" "" >/dev/null 2>&1; then
  no "internal_build + tag 竟然通过（内部构建能手滑发正式版）"
else
  ok "internal_build + tag → 失败"
fi

: > "$TMP/out-creds"
if run_creds branch true true "" "" "" >/dev/null 2>&1; then
  no "internal_build + REQUIRE_NOTARIZATION=true 竟然通过（配置矛盾未拦截）"
else
  ok "internal_build + REQUIRE_NOTARIZATION=true → 失败"
fi

: > "$TMP/out-creds"
if run_creds branch true false "" "" "" >/dev/null 2>&1; then
  grep -qx 'ready=false' "$TMP/out-creds" \
    && ok "internal_build + 非 tag + 无凭据 → 通过且 ready=false" \
    || no "internal_build 路径输出 ready 不正确"
else
  no "internal_build + 非 tag + 无凭据 竟然失败"
fi

: > "$TMP/out-creds"
if run_creds branch false false "" "" "" >/dev/null 2>&1; then
  no "正式路径 REQUIRE_NOTARIZATION=false 竟然通过（公证门禁被关掉）"
else
  ok "正式路径 REQUIRE_NOTARIZATION=false → 失败"
fi

: > "$TMP/out-creds"
if run_creds branch false true "" "" "" >/dev/null 2>&1; then
  grep -qx 'ready=false' "$TMP/out-creds" \
    && ok "正式路径 + 0/3 凭据 + 非 tag → ready=false（随后会 BLOCKED）" \
    || no "0/3 凭据输出 ready 不正确"
else
  no "正式路径 + 0/3 凭据 + 非 tag 竟然失败"
fi

: > "$TMP/out-creds"
if run_creds tag false true "" "" "" >/dev/null 2>&1; then
  no "tag + 0/3 凭据 竟然通过（tag 必须可公证）"
else
  ok "tag + 0/3 公证凭据 → 失败"
fi

: > "$TMP/out-creds"
if run_creds tag false true "KEYID12345" "11111111-2222-3333-4444-555555555555" "c29tZS1rZXk=" >/dev/null 2>&1; then
  grep -qx 'ready=true' "$TMP/out-creds" \
    && ok "tag + 3/3 凭据 → ready=true" \
    || no "3/3 凭据输出 ready 不正确"
else
  no "tag + 3/3 公证凭据 竟然失败"
fi

# ---------------------------------------------------------------------------
hdr "5. 权限划分"
WP="$(ruby -rjson -e 'puts JSON.parse(File.read(ARGV[0]))["workflow_permissions"].to_json' "$TMP/wf.json")"
BP="$(ruby -rjson -e 'puts JSON.parse(File.read(ARGV[0]))["build_permissions"].to_json' "$TMP/wf.json")"
RP="$(ruby -rjson -e 'puts JSON.parse(File.read(ARGV[0]))["release_permissions"].to_json' "$TMP/wf.json")"

case "$WP" in
  *'"contents":"read"'*) ok "workflow 级权限为 contents: read" ;;
  *) no "workflow 级权限不是只读：${WP}" ;;
esac
case "$BP" in
  *write*) no "build job 拿到了写权限：${BP}" ;;
  *'"contents":"read"'*) ok "build job 显式只读：${BP}" ;;
  *) no "build job 权限未显式声明只读：${BP}" ;;
esac
case "$RP" in
  *'"contents":"write"'*) ok "release job 独占 contents: write" ;;
  *) no "release job 没有写权限，无法创建 Release：${RP}" ;;
esac

# ---------------------------------------------------------------------------
hdr "6. 公证脚本不得存在伪造成功路径"
guard_line="$(grep -n 'R_APPLE_STATUS" != "Accepted"' "$NOTARIZE" | head -1 | cut -d: -f1)"
accepted_line="$(grep -n 'R_STATUS="ACCEPTED"' "$NOTARIZE" | head -1 | cut -d: -f1)"
if [ -n "$guard_line" ] && [ -n "$accepted_line" ] && [ "$accepted_line" -gt "$guard_line" ]; then
  ok "R_STATUS=ACCEPTED 只在 Apple 返回 Accepted 的分支之后（第 ${accepted_line} 行 > 守卫第 ${guard_line} 行）"
else
  no "notarize.sh 的 ACCEPTED 赋值不在 Accepted 守卫之后（guard=${guard_line:-无} accepted=${accepted_line:-无}）"
fi

if grep -q 'NOTARIZATION_STATUS=.*ACCEPTED\|NOTARIZATION_STATUS="ACCEPTED"' "$NOTARIZE"; then
  no "notarize.sh 里出现了直接把 NOTARIZATION_STATUS 设成 ACCEPTED 的写法"
else
  ok "notarize.sh 没有硬编码 NOTARIZATION_STATUS=ACCEPTED"
fi

n_stapler="$(grep -c 'stapler validate' "$VERIFY")"
if [ "$n_stapler" -ge 2 ]; then
  ok "verify-release.sh 保留 ${n_stapler} 处 stapler validate 硬断言（dmg + app）"
else
  no "verify-release.sh 的 stapler validate 断言少于 2 处（${n_stapler}）"
fi
if grep -q '\*) fail "公证状态为' "$VERIFY"; then
  ok "verify-release.sh 拒绝非 ACCEPTED 的公证状态"
else
  no "verify-release.sh 未拒绝非 ACCEPTED 状态"
fi

echo
# ---------------------------------------------------------------------------
hdr "7. 内部测试构建的产物身份：命名 / 公证步骤 / DMG 标记"
ruby -ryaml -rjson -e '
wf = YAML.load_file(ARGV[0])
build = wf.dig("jobs", "build")
res = {}
res["artifact_name"] = (build["steps"].find { |s| s["uses"].to_s.include?("upload-artifact") } || {})["with"]["name"]
notarize = build["steps"].find { |s| s["name"].to_s.include?("Apple 公证") }
res["notarize_if"] = notarize && notarize["if"]
res["internal_input"] = wf.dig(true, "workflow_dispatch", "inputs", "internal_build") || wf.dig("on", "workflow_dispatch", "inputs", "internal_build")
File.write(ARGV[1], JSON.pretty_generate(res))
' "$WF" "$TMP/internal.json" || die "解析内部构建结构失败"

INT_NAME="$(ruby -rjson -e 'd=JSON.parse(File.read(ARGV[0])); puts d["artifact_name"]' "$TMP/internal.json")"
INT_IF="$(ruby -rjson -e 'd=JSON.parse(File.read(ARGV[0])); puts(d["notarize_if"] || "")' "$TMP/internal.json")"
INT_INPUT="$(ruby -rjson -e 'd=JSON.parse(File.read(ARGV[0])); puts(d.key?("internal_input") && d["internal_input"] ? "yes" : "no")' "$TMP/internal.json")"
echo "  artifact name = ${INT_NAME}"
echo "  notarize if   = ${INT_IF}"

case "$INT_NAME" in
  *internal-test*version*short_sha*) ok "内部构建产物名包含 internal-test + 版本 + commit SHA" ;;
  *) no "内部构建产物名未同时包含 internal-test / version / short_sha：${INT_NAME}" ;;
esac
case "$INT_NAME" in
  *"inputs.internal_build == true"*internal-test*) ok "产物名先按 internal_build 分支到 internal-test，不会被 signed-notarized 抢走" ;;
  *) no "产物名表达式的分支顺序不对：${INT_NAME}" ;;
esac
if printf '%s' "$INT_IF" | grep -q "INTERNAL_BUILD != 'true'"; then
  ok "Apple 公证步骤在 internal_build=true 时被跳过：${INT_IF}"
else
  no "Apple 公证步骤缺少 internal_build 守卫（当前：${INT_IF:-无}）"
fi
[ "$INT_INPUT" = "yes" ] && ok "internal_build 只定义在 workflow_dispatch 下（push/tag 无法设置）" || no "internal_build 不是 workflow_dispatch 专属输入"

# DMG 内标记与包内说明文件必须真的由 package-release.sh 写入
if grep -q 'INTERNAL_TEST_BUILD.txt' "$REPO_ROOT/scripts/package-release.sh" \
   && grep -q 'INTERNAL TEST BUILD - NOT NOTARIZED' "$REPO_ROOT/scripts/package-release.sh"; then
  ok "package-release.sh 会把 INTERNAL TEST BUILD 标记写进 DMG 与包内说明文件"
else
  no "package-release.sh 缺少 DMG 内外标记的写入逻辑"
fi

# 内部构建必须先过 verify-release.sh 的 unsigned 断言
if grep -q '内部测试包只能未签名' "$VERIFY"; then
  ok "verify-release.sh 拒绝 internal_build 走签名路径"
else
  no "verify-release.sh 未把 internal_build 限制在 unsigned"
fi

echo
echo "小计: PASS=${PASS} FAIL=${FAIL}"
[ "$FAIL" -eq 0 ] || exit 1
echo "发布门禁回归测试全部通过"
