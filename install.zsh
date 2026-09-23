#!/bin/zsh
set -euo pipefail

ROOT_DIR="${0:A:h}"
RUNTIME_DIR="$HOME/Library/Application Support/CodexWindowKicker"
LAUNCH_AGENTS_DIR="$HOME/Library/LaunchAgents"
PLIST_NAME="com.codex-window-kicker.agent.plist"
LABEL="com.codex-window-kicker.agent"
LEGACY_LABEL="com.stephenjoly.codex-window-kicker"
LEGACY_PLIST="$LAUNCH_AGENTS_DIR/com.stephenjoly.codex-window-kicker.plist"

HAS_BREW=0
command -v brew >/dev/null 2>&1 && HAS_BREW=1

# Map each dependency to its brew install command
declare -A BREW_INSTALL=(
  [codexbar]="brew install steipete/tap/codexbar"
  [codex]="brew install codex"
  [jq]="brew install jq"
)

declare -A BREW_DESCRIPTION=(
  [codexbar]="CodexBar CLI — reports Codex usage status"
  [codex]="Codex CLI — OpenAI's coding agent"
  [jq]="jq — command-line JSON processor"
)

missing=()
for cmd in codexbar codex jq; do
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
cp "$ROOT_DIR/bin/codex-window-kicker.zsh" "$RUNTIME_DIR/codex-window-kicker.zsh"
chmod +x "$RUNTIME_DIR/codex-window-kicker.zsh"
cp "$ROOT_DIR/bin/codex-window-kicker-control.zsh" "$RUNTIME_DIR/codex-window-kicker-control.zsh"
chmod +x "$RUNTIME_DIR/codex-window-kicker-control.zsh"
/usr/bin/sed \
  -e "s|__HOME__|$HOME|g" \
  -e "s|__PATH__|$PATH|g" \
  "$ROOT_DIR/launchd/$PLIST_NAME.template" > "$LAUNCH_AGENTS_DIR/$PLIST_NAME"

launchctl bootout "gui/$(id -u)" "$LAUNCH_AGENTS_DIR/$PLIST_NAME" 2>/dev/null || true
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
launchctl bootout "gui/$(id -u)/$LEGACY_LABEL" 2>/dev/null || true
rm -f "$LEGACY_PLIST"

"$RUNTIME_DIR/codex-window-kicker-control.zsh" on

echo "Installed $LABEL"
echo "Logs: $RUNTIME_DIR/codex-window-kicker.log"
echo "Control: $RUNTIME_DIR/codex-window-kicker-control.zsh <on|off|status>"
