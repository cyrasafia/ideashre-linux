#!/usr/bin/env bash
# 解包官方 deb 到 unpack/<name>/，便于分析文件与依赖
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${ROOT}/unpack"

usage() {
    echo "用法: $0 [kylin|uos|all]"
    exit 1
}

unpack_one() {
    local name="$1" deb="${ROOT}/packages/${2}"
    local dest="${OUT}/${name}"
    [ -f "$deb" ] || { echo "未找到 ${deb}"; exit 1; }
    rm -rf "$dest"
    mkdir -p "$dest/control" "$dest/data"
    local tmp
    tmp="$(mktemp -d)"
    (cd "$tmp" && ar x "$deb" && bsdtar -xf control.tar.* -C "$dest/control" && bsdtar -xf data.tar.* -C "$dest/data")
    rm -rf "$tmp"
    echo "已解包 ${deb} -> ${dest}"
}

[ $# -eq 0 ] && set -- all
case "$1" in
    kylin) unpack_one kylin kylinOS_x86_64.deb ;;
    uos)   unpack_one uos uos_x86_64.deb ;;
    all)   unpack_one kylin kylinOS_x86_64.deb
           unpack_one uos uos_x86_64.deb ;;
    *)     usage ;;
esac
