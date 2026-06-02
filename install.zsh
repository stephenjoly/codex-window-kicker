#!/bin/zsh
set -euo pipefail

ROOT_DIR="${0:A:h}"
RUNTIME_DIR="$HOME/Library/Application Support/CodexWindowKicker"
LAUNCH_AGENTS_DIR="$HOME/Library/LaunchAgents"
PLIST_NAME="com.codex-window-kicker.agent.plist"
LABEL="com.codex-window-kicker.agent"
LEGACY_LABEL="com.stephenjoly.codex-window-kicker"
LEGACY_PLIST="$LAUNCH_AGENTS_DIR/com.stephenjoly.codex-window-kicker.plist"

require_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing required command: $1" >&2
    exit 1
  fi
}

require_command codexbar
require_command codex
require_command jq

mkdir -p "$RUNTIME_DIR" "$LAUNCH_AGENTS_DIR"
cp "$ROOT_DIR/bin/codex-window-kicker.zsh" "$RUNTIME_DIR/codex-window-kicker.zsh"
chmod +x "$RUNTIME_DIR/codex-window-kicker.zsh"
/usr/bin/sed \
  -e "s|__HOME__|$HOME|g" \
  -e "s|__PATH__|$PATH|g" \
  "$ROOT_DIR/launchd/$PLIST_NAME.template" > "$LAUNCH_AGENTS_DIR/$PLIST_NAME"

launchctl bootout "gui/$(id -u)" "$LAUNCH_AGENTS_DIR/$PLIST_NAME" 2>/dev/null || true
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
launchctl bootout "gui/$(id -u)/$LEGACY_LABEL" 2>/dev/null || true
rm -f "$LEGACY_PLIST"

launchctl bootstrap "gui/$(id -u)" "$LAUNCH_AGENTS_DIR/$PLIST_NAME"
launchctl kickstart -k "gui/$(id -u)/$LABEL"

echo "Installed $LABEL"
echo "Logs: $RUNTIME_DIR/codex-window-kicker.log"
