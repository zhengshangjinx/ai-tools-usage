#!/bin/bash
# 一键 Release 构建通用二进制（arm64 + x86_64）。
# 用法：scripts/build.sh [Debug|Release]（默认 Release）
#
# 构建完的导出是可选的：scheme 的 post-action 会调 scripts/export.sh，
# 而它只在配了输出目录时才真的打包（见该脚本头部说明）。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG="${1:-Release}"
cd "$ROOT"

command -v xcodegen >/dev/null || { echo "缺少 xcodegen：brew install xcodegen" >&2; exit 1; }
xcodegen generate >/dev/null

xcodebuild -project AIUsage.xcodeproj -scheme AIUsage -configuration "$CONFIG" \
  -derivedDataPath build ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO build \
  | grep -E "error:|\*\* BUILD|\[export\]" || true

# 导出由 scheme 的 post-action（scripts/export.sh）完成，Xcode 内 Build 同样会触发
APP="$ROOT/build/Build/Products/$CONFIG/AI Usage.app"
[[ -d "$APP" ]] || { echo "构建失败，未找到 $APP" >&2; exit 1; }
