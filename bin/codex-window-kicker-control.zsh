#!/bin/zsh
set -euo pipefail

APP_NAME="CodexWindowKicker"
RUNTIME_DIR="${RUNTIME_DIR:-$HOME/Library/Application Support/$APP_NAME}"
STATE_DIR="${STATE_DIR:-$RUNTIME_DIR/state}"
STATUS_FILE="$STATE_DIR/status.json"
ENABLED_STATE_FILE="$STATE_DIR/enabled"
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

wait_for_worker_lock() {
  local lock_dir="$STATE_DIR/lock"
  local attempts=0
  while [[ -d "$lock_dir" && "$attempts" -lt 30 ]]; do
    sleep 0.1
    attempts=$((attempts + 1))
  done
}

write_enabled_state() {
  local enabled="$1"
  local temporary="$STATE_DIR/.enabled.$$.tmp"
  mkdir -p "$STATE_DIR"
  (
    umask 077
    printf '%s\n' "$enabled" >| "$temporary"
    mv -f "$temporary" "$ENABLED_STATE_FILE"
  )
}

# Retain every worker-owned field and replace only enabled. The same-directory
# rename keeps status readers from observing a partially written document.
reconcile_status_enabled() {
  local enabled="$1"
  local temporary="$STATE_DIR/.status-control.$$.tmp"
  mkdir -p "$STATE_DIR"

  if [[ -f "$STATUS_FILE" ]] && /usr/bin/awk -v enabled="$enabled" '
    /"enabled"[[:space:]]*:/ {
      sub(/(true|false)/, enabled)
      found = 1
    }
    { print }
    END { exit(found ? 0 : 1) }
  ' "$STATUS_FILE" >| "$temporary"; then
    mv -f "$temporary" "$STATUS_FILE"
    return 0
  fi

  rm -f "$temporary"
  (
    umask 077
    {
      printf '{\n'
      printf '  "schemaVersion": 1,\n'
      printf '  "enabled": %s,\n' "$enabled"
      printf '  "lastPollAt": null,\n'
      printf '  "usagePercent": null,\n'
      printf '  "resetAt": null,\n'
      printf '  "lastKickoffAt": null,\n'
      printf '  "lastError": null\n'
      printf '}\n'
    } >| "$temporary"
    mv -f "$temporary" "$STATUS_FILE"
  )
}

case "$ACTION" in
  on)
    if [[ ! -f "$PLIST" ]]; then
      echo "Not installed: $PLIST is missing. Run ./install.zsh first." >&2
      exit 1
    fi

    if is_loaded; then
      launchctl kickstart -k "$DOMAIN/$LABEL"
      write_enabled_state true
      reconcile_status_enabled true
      echo "Codex Window Kicker is already enabled and was restarted."
    else
      launchctl bootstrap "$DOMAIN" "$PLIST"
      launchctl kickstart -k "$DOMAIN/$LABEL"
      write_enabled_state true
      reconcile_status_enabled true
      echo "Codex Window Kicker enabled."
    fi
    ;;
  off)
    if is_loaded; then
      # Persist the requested state before stopping launchd. A prompt that is
      # already running will then publish enabled=false if it reaches a final write.
      write_enabled_state false
      if ! launchctl bootout "$DOMAIN/$LABEL"; then
        write_enabled_state true
        reconcile_status_enabled true
        exit 1
      fi
      wait_for_worker_lock
      reconcile_status_enabled false
      echo "Codex Window Kicker disabled. Its files and state were kept."
    else
      write_enabled_state false
      reconcile_status_enabled false
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
