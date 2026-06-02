#!/bin/zsh
set -euo pipefail

ROOT_DIR="${0:A:h}"
RUNTIME_DIR="$HOME/Library/Application Support/CodexWindowKicker"
LAUNCH_AGENTS_DIR="$HOME/Library/LaunchAgents"
PLIST_NAME="com.stephenjoly.codex-window-kicker.plist"

mkdir -p "$RUNTIME_DIR" "$LAUNCH_AGENTS_DIR"
cp "$ROOT_DIR/codex-window-kicker.zsh" "$RUNTIME_DIR/codex-window-kicker.zsh"
chmod +x "$RUNTIME_DIR/codex-window-kicker.zsh"
cp "$ROOT_DIR/$PLIST_NAME" "$LAUNCH_AGENTS_DIR/$PLIST_NAME"

launchctl bootout "gui/$(id -u)" "$LAUNCH_AGENTS_DIR/$PLIST_NAME" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$LAUNCH_AGENTS_DIR/$PLIST_NAME"
launchctl kickstart -k "gui/$(id -u)/com.stephenjoly.codex-window-kicker"

echo "Installed com.stephenjoly.codex-window-kicker"
