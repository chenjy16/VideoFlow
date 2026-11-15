#!/usr/bin/env bash
# 发布门禁回归测试。
#
# 直接解析 .github/workflows/release.yml 里**真实的**表达式与 run 块，而不是另抄一份规则：
#   * internal_build 绝不能触发 Release（只能出 Artifact）
#   * tag 推送走 test-release：unsigned + 不公证 + 创建 GitHub Pre-release，且不读任何 Apple 凭据
#   * tag 的真实签名 / 公证路径只留给 workflow_dispatch（非 internal），缺凭据即 BLOCKED
#   * internal_build 与 tag / 公证 / test_release 全部互斥
#   * 权限划分：build 只读、release 独占 contents: write
#   * 公证脚本不得存在"没拿到 Apple Accepted 就成功"的路径
#   * unsigned 测试发行不得伪造 ACCEPTED，也不得携带公证票据
#
# 用法：./scripts/test-release-gating.sh
#
# 覆盖场景（与需求编号一一对应）：
#   1  tag + 无 Apple Secrets → 允许进入 unsigned test-release 构建
#   2  tag + 无 Apple Secrets → 不得执行 Apple Notarization
#   3  tag + unsigned → 必须设置 ALLOW_UNSIGNED=1
#   4  tag + unsigned → 必须设置 REQUIRE_NOTARIZATION=false
#   5  tag + unsigned → manifest 必须记 NOT_NOTARIZED
#   6  tag + unsigned → DMG 内含 TEST_RELEASE.txt
#   7  tag + 构建成功 → 允许创建 GitHub Pre-release
#   8  tag + 构建失败 → 不得创建 GitHub Release
#   9  tag + 校验失败 → 不得创建 GitHub Release
#   10 tag + internal_build → 不得创建 GitHub Release
#   11 workflow_dispatch + internal_build=true → 仍然只出 Artifact
#   12 无 Apple Secrets 时 tag 不得在 validate 阶段被误拦
#   13 不能靠伪造 NOTARIZATION_STATUS=ACCEPTED 把 unsigned 包变成已公证包
#   14 已存在同名 Release 时必须拒绝覆盖
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
out["release_needs"] = wf.dig("jobs", "release", "needs")
out["build_allow_unsigned"] = wf.dig("jobs", "build", "env", "ALLOW_UNSIGNED")
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
h = { "github" => { "event_name" => ev, "ref_type" => rt, "ref_name" => "v0.1.0" },
      "inputs" => {}, "needs" => {} }
h["inputs"]["internal_build"] = (ib == "true") if %w[true false].include?(ib)
h["inputs"]["dry_run"] = (dry == "true") if %w[true false].include?(dry)
puts JSON.generate(h)
' "$1" "$2" "$3" "$4"
}

ctx_with_needs() { # $1=event $2=ref_type $3=needs JSON（键为 outputs 名）
  ruby -rjson -e '
ev, rt, needs = ARGV
puts JSON.generate({ "github" => { "event_name" => ev, "ref_type" => rt, "ref_name" => "v0.1.0" },
                     "inputs" => {}, "needs" => JSON.parse(needs) })
' "$1" "$2" "$3"
}

# ---------------------------------------------------------------------------
hdr "1. 环境表达式：REQUIRE_NOTARIZATION / INTERNAL_BUILD / TEST_RELEASE（场景 1/3/4/11/12）"
REQ_EXPR="$(ruby -rjson -e 'puts JSON.parse(File.read(ARGV[0]))["env"]["REQUIRE_NOTARIZATION"]' "$TMP/wf.json")"
INT_EXPR="$(ruby -rjson -e 'puts JSON.parse(File.read(ARGV[0]))["env"]["INTERNAL_BUILD"]' "$TMP/wf.json")"
TEST_EXPR="$(ruby -rjson -e 'puts JSON.parse(File.read(ARGV[0]))["env"]["TEST_RELEASE"]' "$TMP/wf.json")"
echo "  REQUIRE_NOTARIZATION = ${REQ_EXPR}"
echo "  INTERNAL_BUILD       = ${INT_EXPR}"
echo "  TEST_RELEASE         = ${TEST_EXPR}"

expect_env() { # $1=event $2=ref_type $3=internal_build $4=dry_run $5=期望 REQUIRE $6=期望 INTERNAL $7=期望 TEST
  local c req int tst
  c="$(ctx "$1" "$2" "$3" "$4")"
  req="$(eval_expr "$REQ_EXPR" "$c")"
  int="$(eval_expr "$INT_EXPR" "$c")"
  tst="$(eval_expr "$TEST_EXPR" "$c")"
  if [ "$req" = "$5" ] && [ "$int" = "$6" ] && [ "$tst" = "$7" ]; then
    ok "$1/$2/internal_build=$3 → REQUIRE=${req} INTERNAL=${int} TEST=${tst}"
  else
    no "$1/$2/internal_build=$3 → 期望 REQUIRE=$5 INTERNAL=$6 TEST=$7，实际 REQUIRE=${req} INTERNAL=${int} TEST=${tst}"
  fi
}

# 场景 1/4/12：tag 推送不需要任何 Apple 凭据，且必须显式把公证要求降为 false
expect_env push               tag    null  null   false false true
# 非 tag 的 push 仍然走“必须公证”的正式路径
expect_env push               branch null  null   true  false false
# rerun / 手动触发打到 tag 上，语义与 tag 推送一致
expect_env workflow_dispatch  tag    false false  false false true
# 普通手动触发（signed 路径，缺凭据即 BLOCKED）
expect_env workflow_dispatch  branch false false  true  false false
# 场景 11：内部构建是唯一能把 REQUIRE 降为 false 的模式，且绝不产生 test_release
expect_env workflow_dispatch  branch true  true   false true  false
expect_env workflow_dispatch  branch true  false  false true  false

# 场景 3：unsigned 必须显式放行（build job 的 ALLOW_UNSIGNED 由 signing_mode 推导）
ALLOW_EXPR="$(ruby -rjson -e 'puts(JSON.parse(File.read(ARGV[0]))["build_allow_unsigned"] || "")' "$TMP/wf.json")"
echo "  ALLOW_UNSIGNED       = ${ALLOW_EXPR}"
if [ -n "$ALLOW_EXPR" ]; then
  au_unsigned="$(eval_expr "$ALLOW_EXPR" "$(ctx_with_needs push tag '{"signing_mode":"unsigned"}')")"
  au_signed="$(eval_expr "$ALLOW_EXPR" "$(ctx_with_needs push tag '{"signing_mode":"developer-id"}')")"
  [ "$au_unsigned" = "1" ] && ok "unsigned 模式 → ALLOW_UNSIGNED=1（未签名不会被默认拦死）" \
                           || no "unsigned 模式的 ALLOW_UNSIGNED=${au_unsigned}，期望 1"
  [ "$au_signed" = "0" ] && ok "developer-id 模式 → ALLOW_UNSIGNED=0（签名路径不允许未签名兜底）" \
                         || no "developer-id 模式的 ALLOW_UNSIGNED=${au_signed}，期望 0"
else
  no "build job 没有声明 ALLOW_UNSIGNED"
fi

# ---------------------------------------------------------------------------
hdr "2. release job 触发条件：只有 tag 构建成功才发布（场景 7/8/9/10/11）"
RELEASE_IF="$(ruby -rjson -e 'puts JSON.parse(File.read(ARGV[0]))["release_if"]' "$TMP/wf.json")"
RELEASE_NEEDS="$(ruby -rjson -e 'puts JSON.parse(File.read(ARGV[0]))["release_needs"].to_json' "$TMP/wf.json")"
echo "  if: ${RELEASE_IF}"
echo "  needs: ${RELEASE_NEEDS}"

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

# 场景 7：tag 推送 + 构建全部通过 → 允许创建 Pre-release
expect_release push                tag    null  null  true
expect_release workflow_dispatch   tag    false false true
expect_release workflow_dispatch   tag    false true  false
# 场景 10：tag 上误加 internal_build（两种模式互斥）→ 绝不发布
expect_release workflow_dispatch   tag    true  false false
expect_release workflow_dispatch   tag    true  true  false
# 非 tag 一律不建 Release
expect_release workflow_dispatch   branch false false false
# 场景 11：internal_build=true 只出 Artifact
expect_release workflow_dispatch   branch true  false false
expect_release workflow_dispatch   branch true  true  false

# 场景 8/9：release job 必须依赖 validate + build，并且不能用 always()/failure() 吞掉上游失败
case "$RELEASE_NEEDS" in
  *build*)
    case "$RELEASE_NEEDS" in
      *validate*) ok "release job 依赖 validate + build：任一失败即不创建 Release（场景 8/9）" ;;
      *) no "release job 没有依赖 validate：${RELEASE_NEEDS}" ;;
    esac
    ;;
  *) no "release job 没有依赖 build，构建失败也可能发布：${RELEASE_NEEDS}" ;;
esac
if printf '%s' "$RELEASE_IF" | grep -q 'always()\|failure()\|cancelled()'; then
  no "release job 的 if 出现 always()/failure()，会绕过构建失败直接发布：${RELEASE_IF}"
else
  ok "release job 的 if 不含 always()/failure()：上游失败不会被忽略"
fi

# ---------------------------------------------------------------------------
hdr "3. 签名判定块：tag = test-release（unsigned），真实签名只留给 dispatch（场景 1/12/13）"
SIGN_BLOCK="$(ruby -rjson -e 'puts JSON.parse(File.read(ARGV[0]))["blocks"]["validate:signing"]' "$TMP/wf.json")"
[ -n "$SIGN_BLOCK" ] || die "未找到 validate/signing 步骤的 run 块"
printf '%s' "$SIGN_BLOCK" > "$TMP/signing.sh"

run_signing() { # $1=ref_type $2=cert $3=pass $4=identity $5=internal_build $6=TEST_RELEASE
  ( cd "$REPO_ROOT" \
    && GITHUB_REF_TYPE="$1" GITHUB_REF_NAME=test GITHUB_SHA=0123456789abcdef \
       GITHUB_OUTPUT="$TMP/out-signing" \
       INTERNAL_BUILD="$5" TEST_RELEASE="$6" \
       APPLE_CERTIFICATE="$2" APPLE_CERTIFICATE_PASSWORD="$3" APPLE_SIGNING_IDENTITY="$4" \
       bash "$TMP/signing.sh" )
}

# 场景 1/12：tag 测试发布在完全没有 Apple Secrets 时必须能通过 validate
: > "$TMP/out-signing"
if run_signing tag "" "" "" false true >/dev/null 2>&1; then
  if grep -qx 'mode=unsigned' "$TMP/out-signing" && grep -qx 'test_release=true' "$TMP/out-signing"; then
    ok "tag + test-release + 0/3 Secrets → unsigned 且 test_release=true"
  else
    no "tag 测试发布输出不正确：$(tr '\n' ' ' < "$TMP/out-signing")"
  fi
else
  no "tag + test-release + 0/3 Secrets 竟然被拦（缺少凭据不该阻止测试发布）"
fi

# tag 测试发布即使环境里残留签名 Secrets，也必须 unsigned（绝不悄悄产出“半正式”包）
: > "$TMP/out-signing"
if run_signing tag "cert" "pass" "Developer ID Application: X (TEAM123456)" false true >/dev/null 2>&1; then
  if grep -qx 'mode=unsigned' "$TMP/out-signing" && ! grep -q 'mode=developer-id' "$TMP/out-signing"; then
    ok "tag + test-release + 3/3 Secrets → 仍强制 unsigned（不读取签名凭据）"
  else
    no "tag 测试发布被签名 Secrets 影响，unsigned 承诺失效"
  fi
else
  no "tag + test-release + 3/3 Secrets 竟然失败"
fi

# test_release 与 internal_build 互斥（场景 10 的前置条件）
: > "$TMP/out-signing"
if run_signing tag "" "" "" true true >/dev/null 2>&1; then
  no "TEST_RELEASE + INTERNAL_BUILD 在签名判定阶段没被拦住"
else
  ok "TEST_RELEASE + INTERNAL_BUILD → 失败（互斥）"
fi

# 真实签名路径（TEST_RELEASE=false）仍然严格：tag 缺凭据必须失败
: > "$TMP/out-signing"
if run_signing tag "" "" "" false false >/dev/null 2>&1; then
  no "tag + TEST_RELEASE=false + 0/3 Secrets 竟然通过（正式路径被测试模式带松）"
else
  ok "tag + TEST_RELEASE=false + 0/3 Secrets → 失败"
fi

: > "$TMP/out-signing"
if run_signing tag "x" "" "" false false >/dev/null 2>&1; then
  no "tag + TEST_RELEASE=false + 1/3 Secrets 竟然通过（半配置未拦截）"
else
  ok "tag + TEST_RELEASE=false + 1/3 Secrets → 失败"
fi

: > "$TMP/out-signing"
if run_signing tag "cert" "pass" "Developer ID Application: X (TEAM123456)" false false >/dev/null 2>&1; then
  if grep -qx 'mode=developer-id' "$TMP/out-signing" && grep -qx 'test_release=false' "$TMP/out-signing"; then
    ok "tag + TEST_RELEASE=false + 3/3 Secrets → developer-id（未来正式签名能力保留）"
  else
    no "tag 正式签名路径的 mode/test_release 输出不正确"
  fi
else
  no "tag + TEST_RELEASE=false + 3/3 Secrets 竟然失败"
fi

: > "$TMP/out-signing"
if run_signing branch "" "" "" false false >/dev/null 2>&1; then
  grep -qx 'mode=unsigned' "$TMP/out-signing" \
    && ok "非 tag + TEST_RELEASE=false + 0/3 Secrets → unsigned" \
    || no "非 tag + 0/3 Secrets 输出 mode 不正确"
else
  no "非 tag + 0/3 Secrets 竟然失败"
fi

# internal_build 即便配齐了签名 Secrets 也必须是 unsigned（否则内部包带签名却无公证）
: > "$TMP/out-signing"
if run_signing branch "cert" "pass" "Developer ID Application: X (TEAM123456)" true false >/dev/null 2>&1; then
  if grep -qx 'mode=unsigned' "$TMP/out-signing" && grep -qx 'test_release=false' "$TMP/out-signing"; then
    ok "internal_build + 非 tag + 3/3 Secrets → 强制 unsigned 且 test_release=false"
  else
    no "internal_build 没能强制 unsigned"
  fi
else
  no "internal_build + 非 tag + 3/3 Secrets 竟然失败"
fi

# internal_build 永远不能用于 tag 发布
: > "$TMP/out-signing"
if run_signing tag "cert" "pass" "Developer ID Application: X (TEAM123456)" true false >/dev/null 2>&1; then
  no "internal_build + tag 在签名判定阶段没被拦住"
else
  ok "internal_build + tag → 失败"
fi

# ---------------------------------------------------------------------------
hdr "4. 公证凭据判定块：tag 测试发布完全不看 Apple 凭据（场景 2/12），正式路径不变"
CREDS_BLOCK="$(ruby -rjson -e 'puts JSON.parse(File.read(ARGV[0]))["blocks"]["validate:notarize_creds"]' "$TMP/wf.json")"
[ -n "$CREDS_BLOCK" ] || die "未找到 validate/notarize_creds 步骤的 run 块"
printf '%s' "$CREDS_BLOCK" > "$TMP/creds.sh"

run_creds() { # $1=ref_type $2=INTERNAL_BUILD $3=REQUIRE_NOTARIZATION $4=key $5=issuer $6=p8 $7=TEST_RELEASE
  ( cd "$REPO_ROOT" \
    && GITHUB_REF_TYPE="$1" GITHUB_OUTPUT="$TMP/out-creds" \
       INTERNAL_BUILD="$2" REQUIRE_NOTARIZATION="$3" TEST_RELEASE="$7" \
       APPLE_API_KEY="$4" APPLE_API_ISSUER="$5" APPLE_API_KEY_P8_BASE64="$6" \
       bash "$TMP/creds.sh" )
}

# 场景 2/12：tag 测试发布在 0/3 凭据时也必须放行，并明确 ready=false（后面不会跑公证）
: > "$TMP/out-creds"
if run_creds tag false false "" "" "" true >/dev/null 2>&1; then
  grep -qx 'ready=false' "$TMP/out-creds" \
    && ok "tag + test-release + 0/3 凭据 → 放行且 ready=false（不会执行 Apple Notarization）" \
    || no "tag 测试发布的 ready 输出不正确"
else
  no "tag + test-release + 0/3 凭据竟然失败（导致 tag 发布被误拦）"
fi

# 场景 2：即使环境里残留了完整凭据，测试发布也不应进入公证分支
: > "$TMP/out-creds"
if run_creds tag false false "KEYID12345" "11111111-2222-3333-4444-555555555555" "c29tZS1rZXk=" true >/dev/null 2>&1; then
  grep -qx 'ready=false' "$TMP/out-creds" \
    && ok "tag + test-release + 3/3 凭据 → ready=false（残留凭据也不能触发公证）" \
    || no "tag 测试发布在 3/3 凭据下错误地 ready=true"
else
  no "tag + test-release + 3/3 凭据竟然失败"
fi

# test_release 绝不能要求公证（该模式的定义就是 notarization-free）
: > "$TMP/out-creds"
if run_creds tag false true "" "" "" true >/dev/null 2>&1; then
  no "TEST_RELEASE + REQUIRE_NOTARIZATION=true 竟然通过（公证门禁被矛盾配置绕过）"
else
  ok "TEST_RELEASE + REQUIRE_NOTARIZATION=true → 失败"
fi

# 正式签名路径（TEST_RELEASE=false）保持 Phase 4 语义不变
: > "$TMP/out-creds"
if run_creds tag true false "" "" "" false >/dev/null 2>&1; then
  no "internal_build + tag 竟然通过（内部构建能手滑发正式版）"
else
  ok "internal_build + tag → 失败"
fi

: > "$TMP/out-creds"
if run_creds branch true true "" "" "" false >/dev/null 2>&1; then
  no "internal_build + REQUIRE_NOTARIZATION=true 竟然通过（配置矛盾未拦截）"
else
  ok "internal_build + REQUIRE_NOTARIZATION=true → 失败"
fi

: > "$TMP/out-creds"
if run_creds branch true false "" "" "" false >/dev/null 2>&1; then
  grep -qx 'ready=false' "$TMP/out-creds" \
    && ok "internal_build + 非 tag + 无凭据 → 通过且 ready=false" \
    || no "internal_build 路径输出 ready 不正确"
else
  no "internal_build + 非 tag + 无凭据 竟然失败"
fi

: > "$TMP/out-creds"
if run_creds branch false false "" "" "" false >/dev/null 2>&1; then
  no "正式路径 REQUIRE_NOTARIZATION=false 竟然通过（公证门禁被关掉）"
else
  ok "正式路径 REQUIRE_NOTARIZATION=false → 失败"
fi

: > "$TMP/out-creds"
if run_creds branch false true "" "" "" false >/dev/null 2>&1; then
  grep -qx 'ready=false' "$TMP/out-creds" \
    && ok "正式路径 + 0/3 凭据 + 非 tag → ready=false（随后会 BLOCKED）" \
    || no "0/3 凭据输出 ready 不正确"
else
  no "正式路径 + 0/3 凭据 + 非 tag 竟然失败"
fi

: > "$TMP/out-creds"
if run_creds tag false true "" "" "" false >/dev/null 2>&1; then
  no "tag + TEST_RELEASE=false + 0/3 凭据 竟然通过（正式发布必须可公证）"
else
  ok "tag + TEST_RELEASE=false + 0/3 公证凭据 → 失败（Phase 4 门禁未削弱）"
fi

: > "$TMP/out-creds"
if run_creds tag false true "KEYID12345" "11111111-2222-3333-4444-555555555555" "c29tZS1rZXk=" false >/dev/null 2>&1; then
  grep -qx 'ready=true' "$TMP/out-creds" \
    && ok "tag + TEST_RELEASE=false + 3/3 凭据 → ready=true（真实公证路径仍可用）" \
    || no "3/3 凭据输出 ready 不正确"
else
  no "tag + TEST_RELEASE=false + 3/3 公证凭据 竟然失败"
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
# 产物名三分支：internal_build → internal-test；tag → test-release；其余 → signed-notarized / internal-unsigned
int_pos="$(printf '%s' "$INT_NAME" | grep -bo 'videoflow-internal-test' | head -1 | cut -d: -f1)"
test_pos="$(printf '%s' "$INT_NAME" | grep -bo 'videoflow-test-release' | head -1 | cut -d: -f1)"
signed_pos="$(printf '%s' "$INT_NAME" | grep -bo 'signed-notarized' | head -1 | cut -d: -f1)"
if [ -n "$int_pos" ] && [ -n "$test_pos" ] && [ -n "$signed_pos" ] \
   && [ "$int_pos" -lt "$test_pos" ] && [ "$test_pos" -lt "$signed_pos" ]; then
  ok "产物名分支顺序为 internal-test → test-release → signed，三模式互不串用"
else
  no "产物名分支顺序不对（internal=${int_pos:-无} test=${test_pos:-无} signed=${signed_pos:-无}）：${INT_NAME}"
fi
if printf '%s' "$INT_NAME" | grep -q 'videoflow-test-release-{0}-{1}'; then
  ok "tag 测试发布产物名包含 test-release + 版本 + commit SHA（场景 7）"
else
  no "tag 测试发布产物名不完整：${INT_NAME}"
fi
if printf '%s' "$INT_IF" | grep -q "INTERNAL_BUILD != 'true'" \
   && printf '%s' "$INT_IF" | grep -q "TEST_RELEASE != 'true'"; then
  ok "Apple 公证步骤在 internal_build / test_release 下都被跳过（场景 2）"
else
  no "Apple 公证步骤缺少 internal_build 或 test_release 守卫（当前：${INT_IF:-无}）"
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
# ---------------------------------------------------------------------------
hdr "8. tag 测试发行的产物身份：命名 / DMG 标记 / manifest / Pre-release（场景 5/6/7/13/14）"
PKG="${REPO_ROOT}/scripts/package-release.sh"
CHECKSUMS="${REPO_ROOT}/scripts/generate-checksums.sh"
[ -f "$PKG" ] || die "找不到 $PKG"
[ -f "$CHECKSUMS" ] || die "找不到 $CHECKSUMS"

# Phase 7 起测试发行与正式版同名：文件名不再承载 unsigned 身份，
# 因此必须同时断言“文件名没有标记”与“manifest / DMG 卷内标记仍在”，缺一不可。
if grep -q 'BUILD_TAG="TEST-UNSIGNED"' "$PKG"; then
  no "package-release.sh 仍给测试发行文件名加标记（文件名应与正式版同形）"
else
  ok "测试发行文件名与正式版同形（VideoFlow_<ver>_aarch64.dmg / .app.zip）"
fi
if grep -q 'BUILD_TAG="INTERNAL-TEST-' "$PKG"; then
  ok "internal 构建仍保留 INTERNAL-TEST 文件名标记（与测试发行可区分）"
else
  no "internal 构建的 INTERNAL-TEST 文件名标记被误删"
fi
if grep -qF '"build_kind": "${BUILD_KIND}"' "$PKG" \
   && grep -qF 'embed_dmg_notice "${OUT_DIR}/${DMG_NAME}" "TEST_RELEASE.txt"' "$PKG"; then
  ok "unsigned 身份仍由 manifest build_kind 与 DMG 卷内 TEST_RELEASE.txt 承载"
else
  no "去掉文件名标记后，manifest build_kind 或 DMG 卷内 TEST_RELEASE.txt 缺失"
fi

# 验收要用测试 tag 实跑，validate 必须同时接受 v<version> 与 v<version>-test.<N>
if grep -qF -- '"$pkg"-test.[0-9]*)' "$WF" && grep -qF -- '"$pkg")' "$WF"; then
  ok "validate 同时接受正式 tag（v<version>）与测试 tag（v<version>-test.<N>）"
else
  no "validate 的 tag 形态校验不完整：v0.1.0-test.1 可能直接被拦"
fi

# 场景 6：TEST_RELEASE.txt 必须真的写进 DMG 卷内，写不进去直接中止发布
embed_line="$(grep -n 'embed_dmg_notice "${OUT_DIR}/${DMG_NAME}" "TEST_RELEASE.txt"' "$PKG" | head -1 | cut -d: -f1)"
if [ -n "$embed_line" ]; then
  ok "package-release.sh 把 TEST_RELEASE.txt 写进 DMG 卷内（第 ${embed_line} 行）"
else
  no "package-release.sh 没有把 TEST_RELEASE.txt 写进 DMG"
fi
if [ -n "$embed_line" ] && sed -n "$((embed_line + 1)),$((embed_line + 4))p" "$PKG" | grep -q 'die "无法把 TEST_RELEASE.txt 写进 DMG'; then
  ok "TEST_RELEASE.txt 写入失败会中止发布（不产出没有标识的包）"
else
  no "TEST_RELEASE.txt 写入失败没有阻断发布"
fi
if [ -n "$embed_line" ] && sed -n "1,${embed_line}p" "$PKG" | grep -q '^TEST RELEASE - UNSIGNED - NOT NOTARIZED$'; then
  ok "TEST_RELEASE.txt 首行即为 TEST RELEASE - UNSIGNED - NOT NOTARIZED"
else
  no "TEST_RELEASE.txt 缺少醒目的发布状态标记"
fi

# SHA256SUMS 只能包含真正随包分发的文件：标记文件写进 DMG 后必须从发布目录删除，
# 否则用户 shasum -c 会报 “TEST_RELEASE.txt: No such file or directory”。
if [ -n "$embed_line" ] && sed -n "$((embed_line + 1)),$((embed_line + 10))p" "$PKG" | grep -q 'rm -f "${OUT_DIR}/TEST_RELEASE.txt"'; then
  ok "TEST_RELEASE.txt 写入 DMG 后从发布目录删除，SHA256SUMS 不会指向缺失文件"
else
  no "TEST_RELEASE.txt 写完后仍留在发布目录，SHA256SUMS 会包含用户拿不到的文件"
fi

# 场景 5：manifest 必须如实记录 test-release / unsigned / null 身份 / NOT_NOTARIZED
if grep -q 'BUILD_KIND="test-release"' "$PKG" \
   && grep -q 'DISTRIBUTION_NOTICE="TEST RELEASE - UNSIGNED - NOT NOTARIZED"' "$PKG"; then
  ok "manifest 的 build_kind=test-release、distribution_notice 与包内声明一致"
else
  no "manifest 缺少 test-release 的 build_kind / distribution_notice"
fi
if grep -q 'SIGN_IDENTITY_JSON="null"' "$PKG" && grep -q 'NOTARY_METHOD="none"' "$PKG"; then
  ok "manifest 的 signing.identity/team_id 为 null、notarization.method 为 none"
else
  no "manifest 仍会写出伪造的签名身份或公证方式"
fi
if grep -q 'TEST_RELEASE 的公证状态必须是 NOT_NOTARIZED' "$PKG"; then
  ok "package-release.sh 拒绝把测试发行标成非 NOT_NOTARIZED（场景 13）"
else
  no "package-release.sh 未拦截测试发行的伪造公证状态"
fi

# 需求 9：DMG 会因写入标记而重建，SHA256 必须针对最终文件
dmgsha_line="$(grep -n 'dmg_sha="$(sidecar_sha "${OUT_DIR}/${DMG_NAME}")' "$PKG" | head -1 | cut -d: -f1)"
sums_line="$(grep -n 'generate-checksums.sh' "$PKG" | head -1 | cut -d: -f1)"
if [ -n "$embed_line" ] && [ -n "$dmgsha_line" ] && [ -n "$sums_line" ] \
   && [ "$dmgsha_line" -gt "$embed_line" ] && [ "$sums_line" -gt "$embed_line" ]; then
  ok "dmg_sha 与 SHA256SUMS 都在 DMG 重建之后生成（行 ${embed_line} < ${dmgsha_line} / ${sums_line}）"
else
  no "校验和可能在 DMG 重建之前生成：embed=${embed_line:-无} dmg_sha=${dmgsha_line:-无} sums=${sums_line:-无}"
fi

# 场景 7：tag 测试发布创建的是 Pre-release，标题与内容都带 Test Release 标记
if grep -q -- '--prerelease' "$WF"; then
  ok "release job 用 gh release create --prerelease 创建 Pre-release（场景 7）"
else
  no "release job 没有 --prerelease，测试发行会被误当正式版"
fi
if grep -q ' - Test Release"' "$WF"; then
  ok "Release 标题带 “ - Test Release” 后缀"
else
  no "Release 标题没有 Test Release 标记"
fi
if grep -q 'isPrerelease' "$WF"; then
  ok "创建后回读 isPrerelease，防止 Pre-release 标记丢失"
else
  no "创建后没有断言 isPrerelease"
fi

# 场景 14：不得覆盖已有 Tag / Release
if grep -q -- '--verify-tag' "$WF" && grep -q 'gh release view "${TAG_NAME}" --repo' "$WF"; then
  ok "创建前用 gh release view 拒绝覆盖已有 Release，并 --verify-tag 绑定已存在 tag（场景 14）"
else
  no "release job 缺少覆盖保护（gh release view / --verify-tag）"
fi
if grep -q 'm.notarization?.status !== "NOT_NOTARIZED"' "$WF" \
   && grep -q 'm.notarization?.ticket_stapled?.dmg !== false' "$WF"; then
  ok "release job 复核 manifest：测试发布必须 NOT_NOTARIZED 且不得带票据（场景 5/13）"
else
  no "release job 没有复核测试发布的公证状态与票据"
fi

# 场景 9：校验失败时 release job 拿不到候选产物
if grep -q 'if-no-files-found: error' "$WF"; then
  ok "产物上传失败即 job 失败，release job 拿不到候选包（场景 9）"
else
  no "上传步骤没有 if-no-files-found: error，校验失败可能没潦草过去"
fi

echo
# ---------------------------------------------------------------------------
hdr "9. verify-release.sh 行为：测试发行只接受 NOT_NOTARIZED（场景 5/13）"
mkdir -p "$TMP/empty-bundle"
run_verify() { # $1=报告路径 $2..=额外环境变量赋值
  local report="$1"
  shift
  ( cd "$REPO_ROOT" \
    && env BUNDLE_DIR="$TMP/empty-bundle" REPORT_PATH="$report" "$@" \
       bash "$VERIFY" >"${report}.out" 2>&1 )
}

if run_verify "$TMP/v-ok.tsv" TEST_RELEASE=true SIGNING_MODE=unsigned ALLOW_UNSIGNED=1 \
     REQUIRE_NOTARIZATION=false NOTARIZATION_STATUS=NOT_NOTARIZED; then
  no "没有 DMG 时 verify-release.sh 竟然返回成功"
else
  if grep -q '测试发行公证状态为 NOT_NOTARIZED' "$TMP/v-ok.tsv.out"; then
    ok "TEST_RELEASE + NOT_NOTARIZED → 公证状态断言通过（随后因无 DMG 失败，符合预期）"
  else
    no "TEST_RELEASE + NOT_NOTARIZED 未通过公证状态断言"
  fi
fi

expect_verify_fail() { # $1=描述 $2=期望的输出片段 $3..=环境变量
  local desc="$1" needle="$2"
  shift 2
  run_verify "$TMP/v-case.tsv" "$@" >/dev/null 2>&1
  if grep -qF "$needle" "$TMP/v-case.tsv.out" 2>/dev/null; then
    ok "${desc} → 被拒绝"
  else
    no "${desc} 未被拒绝（期望输出包含：${needle}）"
  fi
}

expect_verify_fail "场景 13：伪造 NOTARIZATION_STATUS=ACCEPTED" "拒绝伪造公证状态" \
  TEST_RELEASE=true SIGNING_MODE=unsigned ALLOW_UNSIGNED=1 REQUIRE_NOTARIZATION=false NOTARIZATION_STATUS=ACCEPTED
expect_verify_fail "测试发行却是 developer-id 签名" "测试发行必须 unsigned" \
  TEST_RELEASE=true SIGNING_MODE=developer-id ALLOW_UNSIGNED=1 REQUIRE_NOTARIZATION=false NOTARIZATION_STATUS=NOT_NOTARIZED
expect_verify_fail "test_release 与 internal_build 同时开启" "互斥" \
  TEST_RELEASE=true INTERNAL_BUILD=true SIGNING_MODE=unsigned ALLOW_UNSIGNED=1 REQUIRE_NOTARIZATION=false NOTARIZATION_STATUS=NOT_NOTARIZED
expect_verify_fail "test_release 未显式放行 unsigned" "未显式放行" \
  TEST_RELEASE=true SIGNING_MODE=unsigned ALLOW_UNSIGNED=0 REQUIRE_NOTARIZATION=false NOTARIZATION_STATUS=NOT_NOTARIZED
expect_verify_fail "test_release 却要求公证" "配置矛盾" \
  TEST_RELEASE=true SIGNING_MODE=unsigned ALLOW_UNSIGNED=1 REQUIRE_NOTARIZATION=true NOTARIZATION_STATUS=NOT_NOTARIZED

# Phase 4 的真实公证检查不得因为本轮改动而失效
if grep -q 'REQUIRE_NOTARIZATION=true 但 stapler validate 未通过' "$VERIFY" \
   && grep -q '不是 Apple 返回的 ACCEPTED' "$VERIFY"; then
  ok "verify-release.sh 仍保留真实公证的 stapler + ACCEPTED 硬断言（Phase 4 未削弱）"
else
  no "verify-release.sh 的真实公证断言被削弱了"
fi
if grep -q '不允许伪造 Staple' "$VERIFY"; then
  ok "verify-release.sh 拒绝测试发行携带 Staple 票据（场景 13）"
else
  no "verify-release.sh 未拦截测试发行的伪造票据"
fi

# ---------------------------------------------------------------------------
# 9. unsigned 不等于没有签名：必须做 ad-hoc 签名，否则下载后报「已损坏」
# ---------------------------------------------------------------------------
# 回归背景：v1.0.0 的 .app 在没有任何身份时被 tauri 跳过 codesign，只剩链接器
# 写进 Mach-O 的 ad-hoc 签名（Info.plist 未绑定）。codesign --verify --deep --strict
# 失败，用户从浏览器下载后带 quarantine 启动，macOS 直接报「App 已损坏」。
if grep -qF 'export APPLE_SIGNING_IDENTITY="-"' "$WF"; then
  ok "release.yml 在无 Developer ID 时显式要求 ad-hoc 签名（APPLE_SIGNING_IDENTITY=-）"
else
  no "release.yml 没有在 unsigned 路径要求 ad-hoc 签名，产物会只有链接器签名"
fi
if grep -qF 'if [ "${SIGNING_MODE}" != "developer-id" ]; then' "$WF"; then
  ok "ad-hoc 签名只在非 developer-id 模式生效（不污染真实签名路径）"
else
  no "ad-hoc 签名缺少 SIGNING_MODE 守卫，可能覆盖 Developer ID 签名"
fi
if awk '/AD_HOC（无 Developer ID）/,/测试发行的“unsigned”声明/' "$VERIFY" | grep -q 'codesign --verify --deep --strict'; then
  ok "verify-release.sh 在 unsigned 分支断言 .app 自身签名完整（codesign --verify --deep --strict）"
else
  no "verify-release.sh 的 unsigned 分支只放行不校验，损坏的 .app 会直接发布"
fi
if grep -qF "grep -q '^Signature=adhoc'" "$VERIFY" \
   && grep -qF "grep -q '^Info.plist entries='" "$VERIFY"; then
  ok "verify-release.sh 断言 ad-hoc 签名已绑定 Info.plist（不只是链接器签名）"
else
  no "verify-release.sh 未区分「真 ad-hoc 签名」与「链接器签名」"
fi

echo
echo "小计: PASS=${PASS} FAIL=${FAIL}"
[ "$FAIL" -eq 0 ] || exit 1
echo "发布门禁回归测试全部通过"
