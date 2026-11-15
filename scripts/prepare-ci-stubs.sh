#!/usr/bin/env bash
# 生成编译期占位 sidecar —— 仅供 CI 的编译/静态/单测门禁使用。
#
# 为什么需要：tauri-build 在编译期会校验 tauri.conf.json 里 externalBin 指定的
# 文件是否存在（缺任何一个都会 panic: resource path `binaries/...` doesn't exist）。
# 而真实 sidecar 体积大且按设计不入库（见 .gitignore 的 src-tauri/binaries/），
# 所以纯编译门禁必须自己准备出这三个文件。
#
# 安全边界：
#   * 占位文件带 VIDEOFLOW_CI_STUB 标记，verify-release.sh 会拒绝任何含该标记的
#     二进制，因此它们不可能进入安装包。
#   * 已存在的真实二进制一律跳过，绝不覆盖。
#   * 这里不实现任何引擎功能：CI 不执行下载/转封装，引擎真实性由 release.yml
#     用 FFmpeg LGPL 产物 + fetch-yt-dlp.sh 保证。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN_DIR="${ROOT}/src-tauri/binaries"
TRIPLE="${TRIPLE:-aarch64-apple-darwin}"
MARKER="VIDEOFLOW_CI_STUB"

mkdir -p "${BIN_DIR}"

echo "注意：以下生成物是编译期占位，不是真实引擎，不会进入任何安装包。"

for name in yt-dlp ffmpeg ffprobe; do
  dest="${BIN_DIR}/${name}-${TRIPLE}"

  if [ -f "${dest}" ]; then
    if grep -qa "${MARKER}" "${dest}" 2>/dev/null; then
      echo "  已存在占位文件，重新生成：${dest}"
    else
      echo "  已存在真实二进制，跳过：${dest}"
      continue
    fi
  fi

  cat > "${dest}" <<EOF
#!/bin/sh
# ${MARKER} — 编译期占位，不是真实引擎，禁止打包。
echo "${name} version 0.0.0-videoflow-ci-stub"
EOF
  chmod 755 "${dest}"
  echo "  已生成占位：${dest}"
done

echo "占位 sidecar 就绪。真实引擎请用 scripts/fetch-yt-dlp.sh 与 scripts/build-ffmpeg-lgpl.sh。"
