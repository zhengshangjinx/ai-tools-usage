#!/usr/bin/env bash
#
# 出 README 用的那几张图（docs/images/）。
#
# 走 `--render <临时目录> --demo`：演示模式把扫描 / 计价 / 同步 / 配置域全部换成编好的一套，
# 所以出图不读本机日志、不联网、不写 iCloud，也不会把作者本人的设备名、消费额和
# `/Users/<名字>/...` 路径截进要提交进仓库的图里（见 AIUsage/Demo/DemoRuntime.swift）。
#
# 工装会产出二十多张（三种维度、最小宽度、深色、几个浮层……），这个脚本**只挑 README 要用的
# 那几张**按干净的名字拷进 docs/images/ —— 哪张图进了仓库是一件看得见的事，
# 而不是从一堆 PNG 里碰运气。
#
# 用法：./scripts/shoot.sh [输出目录]

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$ROOT/build/Build/Products/Release/AI Usage.app/Contents/MacOS/AI Usage"
OUT="${1:-$ROOT/docs/images}"

if [ ! -x "$APP" ]; then
    echo "找不到 $APP" >&2
    echo "先跑 ./scripts/build.sh（必要时 xcodegen generate）" >&2
    exit 1
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# 出图不该动到用户真实的配置域（这一条是演示模式存在的全部理由）。这里顺手核一遍 ——
# 断言写在能跑的地方，比写在文档里可靠。
#
# **比的是归一化之后的文本，不是 `defaults export` 出来的字节**：那个 plist 的字节里带着
# 域内部的键序，而键序只要这期间有任何一次写入就可能变（演示模式退出时会把 AppKit 自己写的
# 窗口尺寸还回去，正是一次写入）。内容一字不差、字节却不同，`cmp` 会红得毫无意义。
DOMAIN=com.local.aiusage
snapshot() { defaults export "$DOMAIN" - 2>/dev/null | plutil -convert xml1 -o - - 2>/dev/null; }
before="$(snapshot)"

"$APP" --render "$TMP" --demo

after="$(snapshot)"
if [ "$before" != "$after" ]; then
    echo "真实配置域被改动了（$DOMAIN）：" >&2
    diff <(printf '%s\n' "$before") <(printf '%s\n' "$after") >&2
    exit 1
fi

mkdir -p "$OUT"
# 工装里的名字 → 仓库里的名字。左边一律是浅色的那一张：深色另有 main-dark.png 一张做对照，
# 其余几张深浅排版完全一样，两套都提交只会让这个目录大一倍。
copy() {
    local from="$TMP/$1" to="$OUT/$2"
    if [ ! -f "$from" ]; then
        echo "工装没出这张图：$1" >&2
        exit 1
    fi
    cp "$from" "$to"
    echo "  $2"
}

echo "写入 ${OUT}："
copy main-light.png             main-light.png
copy main-dark.png              main-dark.png
copy main-light-model.png       main-model.png
copy main-light-day.png         main-day.png
copy settings-sources-light.png settings-sources.png
copy settings-display-light.png settings-display.png
copy menubar-panel-light.png    menubar-panel.png
copy model-detail-light.png     model-detail.png

echo
echo "发之前先看一眼：docs/images/README.md 末尾那段自查。"
