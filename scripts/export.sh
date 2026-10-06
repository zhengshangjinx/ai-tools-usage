#!/bin/bash
# 把构建好的 .app 校验为通用二进制（arm64 + x86_64）后打包到指定目录。
# 用法：scripts/export.sh "<path/to/AI Usage.app>" [version]
#
# 输出目录按顺序取：$AIUSAGE_EXPORT_DIR → scripts/export-dir.local 的第一行 → 都没有就**跳过导出**。
# 为什么不给个默认目录：这个脚本挂在 scheme 的 build post-action 上（见 project.yml），
# 任何人构建都会触发。早先它写死了我自己 iCloud 里的一个目录，那等于往每个构建者的
# 个人 iCloud 里塞东西 —— 所以现在没显式配置就什么都不做，只打一行提示。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_PATH="${1:?用法: export.sh <app 路径> [version]}"
# 版本号只有一处事实来源：`project.yml` 的 `MARKETING_VERSION`（scheme 会当第二个参数传进来，
# 见 project.yml 的 postActions）。手跑不带版本时从**产物里**读，不在这儿另写一个默认值 ——
# 写过一次，结果和 project.yml 各说各话。
VERSION="${2:-$(plutil -extract CFBundleShortVersionString raw -o - "$APP_PATH/Contents/Info.plist" 2>/dev/null || echo 0.0.0)}"
NAME="AiToolsUsage"

DEST_DIR="${AIUSAGE_EXPORT_DIR:-}"
if [[ -z "$DEST_DIR" && -f "$ROOT/scripts/export-dir.local" ]]; then
  # `|| true` 不能省：文件里全是注释时 grep 返回 1，在 set -e + pipefail 下会把脚本直接带走
  DEST_DIR="$(grep -v '^[[:space:]]*#' "$ROOT/scripts/export-dir.local" 2>/dev/null \
    | grep -v '^[[:space:]]*$' | head -1 || true)"
fi
# 开头的 ~ 要自己展开：上面那个文件是**逐字读**的，$HOME / ~ 都不会被 shell 处理，
# 不展开就会 mkdir 出一个名字真的叫 "~" 的目录。
DEST_DIR="${DEST_DIR/#\~/$HOME}"
if [[ -z "$DEST_DIR" ]]; then
  echo "[export] 未配置输出目录，跳过导出。要导出的话任选一种："
  echo "[export]   1) AIUSAGE_EXPORT_DIR=\"/path/to/dir\" ./scripts/build.sh"
  echo "[export]   2) 把目录路径写进 scripts/export-dir.local（已在 .gitignore 里，不会提交）"
  exit 0
fi

if [[ ! -d "$APP_PATH" ]]; then
  echo "[export] 找不到产物: $APP_PATH" >&2
  exit 1
fi

# 用 `plutil` 而不是 `defaults read`：后者只认绝对路径，手跑时给个相对路径会栽在这儿
# （报「domain/default pair ... does not exist」，看不出是路径的锅）。
BIN="$APP_PATH/Contents/MacOS/$(plutil -extract CFBundleExecutable raw -o - "$APP_PATH/Contents/Info.plist")"
ARCHS="$(lipo -archs "$BIN")"
echo "[export] 架构: $ARCHS"
for want in arm64 x86_64; do
  if [[ " $ARCHS " != *" $want "* ]]; then
    echo "[export] 产物缺少 $want 架构，跳过导出（请用 ARCHS='arm64 x86_64' ONLY_ACTIVE_ARCH=NO 构建）" >&2
    exit 0
  fi
done

# 临时签名（无开发者证书时 ad-hoc），保证在其他机器上可直接启动
codesign --force --deep --sign - "$APP_PATH" >/dev/null 2>&1 || true

mkdir -p "$DEST_DIR"
# 包名分两种，**Release 的那个必须稳定**：
#
# 它是发布资产，名字要同时对上三处 —— README 里写给用户的
# `AiToolsUsage-<版本>-macos-universal.zip`、线上已发布的 v0.1.0、以及 App 内置更新器
# （`UpdatePolicy.selectAsset` 优先精确匹配这个名字）。
# 原先一律拼 `YYYYMMDD-HHMM`，同一个版本会攒出好几个包，更新器只能靠猜 ——
# 而猜错的症状是「提示你升 0.2.0，装上去还是旧的」，很难查。
#
# 所以：Release 用固定的 `macos-universal`，**不带时间戳**；Debug 才带，它不进发布页，
# 而且连着构建几次不该互相覆盖。
STAMP=""
SUFFIX=""
TAG="macos-universal"
if [[ "${CONFIGURATION:-Release}" != "Release" ]]; then
  STAMP="$(date +%Y%m%d-%H%M)"
  SUFFIX="-$(echo "$CONFIGURATION" | tr '[:upper:]' '[:lower:]')"
  TAG="$STAMP"
fi
ZIP="$DEST_DIR/$NAME-$VERSION-$TAG$SUFFIX.zip"
ditto -c -k --sequesterRsrc --keepParent "$APP_PATH" "$ZIP"

# 同时保留一份可直接双击的最新 .app
rm -rf "$DEST_DIR/AI Usage.app"
ditto "$APP_PATH" "$DEST_DIR/AI Usage.app"

echo "[export] 已输出: $ZIP"
