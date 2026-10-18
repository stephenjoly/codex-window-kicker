#!/bin/zsh
set -euo pipefail

ROOT_DIR="${0:A:h}"
PROVIDER="${1:-codex}"
case "$PROVIDER" in
  codex) DISPLAY_NAME="Codex" ;;
  claude) DISPLAY_NAME="Claude" ;;
  *) echo "Usage: ./install.zsh [codex|claude]" >&2; exit 2 ;;
esac
APP_NAME="${DISPLAY_NAME}WindowKicker"
RUNTIME_DIR="$HOME/Library/Application Support/$APP_NAME"
LAUNCH_AGENTS_DIR="$HOME/Library/LaunchAgents"
PLIST_NAME="com.${PROVIDER}-window-kicker.agent.plist"
LABEL="com.${PROVIDER}-window-kicker.agent"
LEGACY_LABEL="com.stephenjoly.codex-window-kicker"
LEGACY_PLIST="$LAUNCH_AGENTS_DIR/com.stephenjoly.codex-window-kicker.plist"

HAS_BREW=0
command -v brew >/dev/null 2>&1 && HAS_BREW=1

# Map each dependency to its brew install command
declare -A BREW_INSTALL=(
  [codexbar]="brew install steipete/tap/codexbar"
  [codex]="brew install codex"
  [claude]="brew install --cask claude-code"
  [jq]="brew install jq"
)

declare -A BREW_DESCRIPTION=(
  [codexbar]="CodexBar CLI — reports Codex usage status"
  [codex]="Codex CLI — OpenAI's coding agent"
  [claude]="Claude Code CLI — Anthropic's coding agent (requires subscription login)"
  [jq]="jq — command-line JSON processor"
)

missing=()
for cmd in codexbar "$PROVIDER" jq; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    missing+=("$cmd")
  fi
done

if [[ ${#missing[@]} -gt 0 ]]; then
  echo "Missing dependencies:"
  for cmd in "${missing[@]}"; do
    echo "  - ${BREW_DESCRIPTION[$cmd]}"
    echo "    Install: ${BREW_INSTALL[$cmd]}"
  done
  echo ""

  if [[ "$HAS_BREW" -eq 1 ]]; then
    printf "Install them now with Homebrew? [y/N] "
    read -r answer
    if [[ "$answer" =~ ^[Yy]$ ]]; then
      for cmd in "${missing[@]}"; do
        echo "Running: ${BREW_INSTALL[$cmd]}"
        eval "${BREW_INSTALL[$cmd]}"
      done
      echo ""
    else
      echo "Aborting. Install the dependencies above and re-run ./install.zsh" >&2
      exit 1
    fi
  else
    echo "Homebrew not found. Install the dependencies above manually and re-run ./install.zsh" >&2
    exit 1
  fi
fi

mkdir -p "$RUNTIME_DIR" "$LAUNCH_AGENTS_DIR"
cp "$ROOT_DIR/bin/$PROVIDER-window-kicker.zsh" "$RUNTIME_DIR/$PROVIDER-window-kicker.zsh"
chmod +x "$RUNTIME_DIR/$PROVIDER-window-kicker.zsh"
cp "$ROOT_DIR/bin/codex-window-kicker-control.zsh" "$RUNTIME_DIR/$PROVIDER-window-kicker-control.zsh"
chmod +x "$RUNTIME_DIR/$PROVIDER-window-kicker-control.zsh"
/usr/bin/sed \
  -e "s|__HOME__|$HOME|g" \
  -e "s|__PATH__|$PATH|g" \
  -e "s|CodexWindowKicker|$APP_NAME|g" \
  -e "s|codex-window-kicker|$PROVIDER-window-kicker|g" \
  "$ROOT_DIR/launchd/com.codex-window-kicker.agent.plist.template" > "$LAUNCH_AGENTS_DIR/$PLIST_NAME"

launchctl bootout "gui/$(id -u)" "$LAUNCH_AGENTS_DIR/$PLIST_NAME" 2>/dev/null || true
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
if [[ "$PROVIDER" == codex ]]; then
  launchctl bootout "gui/$(id -u)/$LEGACY_LABEL" 2>/dev/null || true
  rm -f "$LEGACY_PLIST"
fi

launchctl bootstrap "gui/$(id -u)" "$LAUNCH_AGENTS_DIR/$PLIST_NAME"
launchctl kickstart -k "gui/$(id -u)/$LABEL"

echo "Installed $LABEL"
echo "Logs: $RUNTIME_DIR/$PROVIDER-window-kicker.log"
echo "Control: $RUNTIME_DIR/$PROVIDER-window-kicker-control.zsh <on|off|status>"
