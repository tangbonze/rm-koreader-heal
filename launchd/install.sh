#!/bin/sh
# 把 rm-koreader-heal --watch 注册成 macOS LaunchAgent（登录自启 + 挂掉自动重启）
#
#   ./launchd/install.sh          安装 / 重新加载
#   ./launchd/uninstall.sh        卸载
#
# 卸载后用 launchctl print gui/$UID/<label> 应查不到该服务。
set -eu

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
SCRIPT="$REPO/rm-koreader-heal.sh"
LABEL="com.tangbonze.rm-koreader-heal"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
LOG="$HOME/.cache/rm-koreader-heal/watch.log"

[ -x "$SCRIPT" ] || { echo "找不到可执行的 $SCRIPT" >&2; exit 1; }

mkdir -p "$HOME/Library/LaunchAgents" "$(dirname "$LOG")"

sed -e "s|__SCRIPT__|$SCRIPT|g" \
    -e "s|__LOG__|$LOG|g" \
    -e "s|__LABEL__|$LABEL|g" \
    "$HERE/$LABEL.plist" > "$PLIST"

plutil -lint "$PLIST" >/dev/null || { echo "生成的 plist 非法：$PLIST" >&2; exit 1; }

# 先卸掉旧的（不存在也无所谓）
launchctl bootout "gui/$UID/$LABEL" 2>/dev/null || true

launchctl bootstrap "gui/$UID" "$PLIST"
launchctl enable "gui/$UID/$LABEL"
launchctl kickstart -k "gui/$UID/$LABEL" 2>/dev/null || true

echo "已安装 LaunchAgent：$PLIST"
echo "日志：$LOG"
echo "查看状态：launchctl print gui/$UID/$LABEL | head -20"
