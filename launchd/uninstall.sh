#!/bin/sh
# 卸载 rm-koreader-heal 的 LaunchAgent
set -eu

LABEL="com.tangbonze.rm-koreader-heal"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"

launchctl bootout "gui/$UID/$LABEL" 2>/dev/null || true
rm -f "$PLIST"

echo "已卸载：$PLIST"
