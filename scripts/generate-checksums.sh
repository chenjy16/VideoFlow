#!/usr/bin/env bash
# 为发布目录生成 SHA256SUMS（排序稳定，便于人工核对）。
#
# 用法：./scripts/generate-checksums.sh [目录]      # 默认 dist-release
set -euo pipefail

DIR="${1:-dist-release}"

die() { echo "错误: $*" >&2; exit 1; }

[ -d "$DIR" ] || die "目录不存在: $DIR"

cd "$DIR"

# 先删旧文件再重建，避免残留旧条目把校验结论带偏
rm -f SHA256SUMS

count=0
while IFS= read -r f; do
  # shasum 输出形如 "<hash>  ./name"，去掉 "./" 前缀便于他人直接校验
  shasum -a 256 "$f" | sed 's|  \./|  |'
  count=$((count + 1))
done < <(find . -maxdepth 1 -type f ! -name 'SHA256SUMS' -print | LC_ALL=C sort) > SHA256SUMS

[ "$count" -gt 0 ] || die "目录里没有可校验的文件: $DIR"

echo "已生成 ${DIR}/SHA256SUMS（${count} 个文件）："
cat SHA256SUMS
