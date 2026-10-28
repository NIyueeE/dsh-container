#!/usr/bin/env bash
# 最低支持上游 dsh 0.2.1-alpha.3。
# 0.2.1-alpha.1/alpha.2 仍把设置持久化绑在 $host.isLoopback 上; 镜像已删除
# __DSH_TRANSPORT__ 兼容行, 因此这两个 tag 会丢设置。alpha.3 起该门已移除。
# 用法: dsh-version-floor <dsh-vX.Y.Z[-pre]>  (Containerfile 构建期使用)
# 退出码: 0 = 支持; 1 = 不支持; 2 = 用法错误
set -euo pipefail

if [ "$#" -ne 1 ]; then
  echo "usage: dsh-version-floor <dsh-vX.Y.Z[-pre]>" >&2
  exit 2
fi

tag="$1"
if ! [[ "$tag" =~ ^dsh-v([0-9]+)\.([0-9]+)\.([0-9]+)(-[0-9A-Za-z.-]+)?$ ]]; then
  echo "unsupported dsh tag '$tag': expected dsh-vX.Y.Z[-pre]" >&2
  exit 1
fi

major=$((10#${BASH_REMATCH[1]}))
minor=$((10#${BASH_REMATCH[2]}))
patch=$((10#${BASH_REMATCH[3]}))

if [ "$major" -eq 0 ] && { [ "$minor" -lt 2 ] || { [ "$minor" -eq 2 ] && [ "$patch" -lt 1 ]; }; }; then
  echo "unsupported dsh tag '$tag': minimum supported upstream dsh is 0.2.1-alpha.3" >&2
  exit 1
fi

case "$tag" in
  dsh-v0.2.1-alpha.[0-2])
    echo "unsupported dsh tag '$tag': 0.2.1-alpha.3 is the first tag without the loopback settings-persistence gate" >&2
    exit 1
    ;;
esac
