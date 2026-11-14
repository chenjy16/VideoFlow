#!/usr/bin/env bash
# 获取构建所需的 yt-dlp sidecar（Tauri externalBin）。
# 二进制体积约 36MB，不纳入版本库；版本与校验和在此固定，保证构建可复现。
#
# 用法：./scripts/fetch-yt-dlp.sh
# 可用 YTDLP_VERSION / YTDLP_SHA256 覆盖（升级时同步修改两处）。
set -euo pipefail

VERSION="${YTDLP_VERSION:-2026.10.26}"
SHA256="${YTDLP_SHA256:-0f922c15ccc0b83eefa1c8bc9104e434318c4bf16e408e1ee93b7745a6efe0aa}"
TRIPLE="aarch64-apple-darwin"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="$ROOT/src-tauri/binaries/yt-dlp-${TRIPLE}"
URL="https://github.com/yt-dlp/yt-dlp/releases/download/${VERSION}/yt-dlp_macos"

verify() {
  shasum -a 256 "$1" | awk '{print $1}'
}

if [[ -x "$DEST" ]]; then
  current="$(verify "$DEST")"
  if [[ "$current" == "$SHA256" ]]; then
    echo "已就绪（校验通过）：$DEST"
    exit 0
  fi
  echo "现有文件校验不一致，将重新下载：$current"
fi

mkdir -p "$(dirname "$DEST")"
tmp="$(mktemp -t yt-dlp).download"
trap 'rm -f "$tmp"' EXIT

echo "下载 yt-dlp ${VERSION} …"
curl -fL --retry 3 --connect-timeout 15 -o "$tmp" "$URL"

actual="$(verify "$tmp")"
if [[ "$actual" != "$SHA256" ]]; then
  echo "校验失败：期望 $SHA256，实际 $actual" >&2
  exit 1
fi

chmod 0755 "$tmp"
mv "$tmp" "$DEST"
echo "已就绪：$DEST"
