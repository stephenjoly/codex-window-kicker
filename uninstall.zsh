#!/bin/zsh
set -euo pipefail

LABEL="com.codex-window-kicker.agent"
PLIST="$HOME/Library/LaunchAgents/com.codex-window-kicker.agent.plist"
RUNTIME_DIR="$HOME/Library/Application Support/CodexWindowKicker"

launchctl bootout "gui/$(id -u)" "$PLIST" 2>/dev/null || true
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
rm -f "$PLIST"

echo "Uninstalled $LABEL"
echo "Runtime files are still at: $RUNTIME_DIR"
