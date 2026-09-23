#!/bin/zsh
set -euo pipefail

APP_NAME="CodexWindowKicker"
RUNTIME_DIR="${RUNTIME_DIR:-$HOME/Library/Application Support/$APP_NAME}"
PLIST="$HOME/Library/LaunchAgents/com.codex-window-kicker.agent.plist"
LABEL="com.codex-window-kicker.agent"
DOMAIN="gui/$(id -u)"
ACTION="${1:-status}"

usage() {
  cat <<'EOF'
Usage: codex-window-kicker-control.zsh <on|off|status>

  on      Load and start the scheduled window kicker.
  off     Stop and unload it without removing its files or state.
  status  Show whether it is loaded.
EOF
}

is_loaded() {
  launchctl print "$DOMAIN/$LABEL" >/dev/null 2>&1
}

case "$ACTION" in
  on)
    if [[ ! -f "$PLIST" ]]; then
      echo "Not installed: $PLIST is missing. Run ./install.zsh first." >&2
      exit 1
    fi

    if is_loaded; then
      launchctl kickstart -k "$DOMAIN/$LABEL"
      echo "Codex Window Kicker is already enabled and was restarted."
    else
      launchctl bootstrap "$DOMAIN" "$PLIST"
      launchctl kickstart -k "$DOMAIN/$LABEL"
      echo "Codex Window Kicker enabled."
    fi
    ;;
  off)
    if is_loaded; then
      launchctl bootout "$DOMAIN/$LABEL"
      echo "Codex Window Kicker disabled. Its files and state were kept."
    else
      echo "Codex Window Kicker is already disabled."
    fi
    ;;
  status)
    if is_loaded; then
      echo "Codex Window Kicker is enabled."
      launchctl print "$DOMAIN/$LABEL"
    else
      echo "Codex Window Kicker is disabled."
    fi
    ;;
  -h|--help|help)
    usage
    ;;
  *)
    usage >&2
    exit 2
    ;;
esac
