#!/bin/zsh
set -euo pipefail

PROVIDER="${1:-codex}"
case "$PROVIDER" in
  codex|claude) ;;
  *) echo "Usage: ./uninstall.zsh [codex|claude]" >&2; exit 2 ;;
esac
LABEL="com.$PROVIDER-window-kicker.agent"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
RUNTIME_DIR="$HOME/Library/Application Support/${(C)PROVIDER}WindowKicker"

launchctl bootout "gui/$(id -u)" "$PLIST" 2>/dev/null || true
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
rm -f "$PLIST"

echo "Uninstalled $LABEL"
echo "Runtime files are still at: $RUNTIME_DIR"
