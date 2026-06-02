#!/bin/zsh
set -u

APP_NAME="CodexWindowKicker"
RUNTIME_DIR="${RUNTIME_DIR:-$HOME/Library/Application Support/$APP_NAME}"
STATE_DIR="${STATE_DIR:-$RUNTIME_DIR/state}"
LOG_PREFIX="${LOG_PREFIX:-codex-window-kicker}"
LOG_FILE="${LOG_FILE:-$RUNTIME_DIR/codex-window-kicker.log}"
LOG_MAX_LINES="${LOG_MAX_LINES:-5000}"
LOG_TRIM_THRESHOLD="${LOG_TRIM_THRESHOLD:-10000}"

POLL_IDLE_SECONDS="${POLL_IDLE_SECONDS:-600}"
SUPPRESS_AFTER_KICK_SECONDS="${SUPPRESS_AFTER_KICK_SECONDS:-16200}" # 4.5 hours
FRESH_WINDOW_MINUTES_MIN="${FRESH_WINDOW_MINUTES_MIN:-285}"
FRESH_WINDOW_MINUTES_MAX="${FRESH_WINDOW_MINUTES_MAX:-315}"
CODEXBAR_SOURCE="${CODEXBAR_SOURCE:-oauth}"
DRY_RUN="${DRY_RUN:-0}"
LOCK_STALE_SECONDS="${LOCK_STALE_SECONDS:-600}"

resolve_binary() {
  local name="$1"
  shift

  for candidate in "$@"; do
    if [[ -x "$candidate" ]]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done

  if command -v "$name" >/dev/null 2>&1; then
    command -v "$name"
    return 0
  fi

  return 1
}

CODEXBAR="${CODEXBAR:-$(resolve_binary codexbar /opt/homebrew/bin/codexbar /usr/local/bin/codexbar)}"
CODEX="${CODEX:-$(resolve_binary codex /opt/homebrew/bin/codex /usr/local/bin/codex)}"
JQ="${JQ:-$(resolve_binary jq /opt/homebrew/bin/jq /usr/local/bin/jq /usr/bin/jq)}"

mkdir -p "$STATE_DIR"
now_epoch="$(date +%s)"

trim_log_file() {
  [[ -f "$LOG_FILE" ]] || return 0
  local line_count
  line_count="$(/usr/bin/wc -l < "$LOG_FILE")"
  line_count="${line_count// /}"
  if [[ "$line_count" -gt "$LOG_TRIM_THRESHOLD" ]]; then
    local kept
    kept="$(/usr/bin/tail -n "$LOG_MAX_LINES" "$LOG_FILE")"
    printf '%s\n' "$kept" >| "$LOG_FILE"
    exec 1>> "$LOG_FILE"
  fi
}

trim_log_file

if [[ -z "${CODEXBAR:-}" || -z "${CODEX:-}" || -z "${JQ:-}" ]]; then
  echo "[$LOG_PREFIX] missing dependency; codexbar=${CODEXBAR:-missing} codex=${CODEX:-missing} jq=${JQ:-missing}"
  exit 0
fi

LOCK_DIR="$STATE_DIR/lock"
LOCK_PID_FILE="$LOCK_DIR/pid"

acquire_lock() {
  if mkdir "$LOCK_DIR" 2>/dev/null; then
    printf '%s\n' "$$" > "$LOCK_PID_FILE"
    return 0
  fi

  local lock_pid=""
  [[ -f "$LOCK_PID_FILE" ]] && lock_pid="$(<"$LOCK_PID_FILE")"

  if [[ -n "$lock_pid" ]] && kill -0 "$lock_pid" 2>/dev/null; then
    local lock_mtime lock_age
    lock_mtime="$(stat -f '%m' "$LOCK_DIR" 2>/dev/null)" || lock_mtime="$now_epoch"
    lock_age=$((now_epoch - lock_mtime))
    if [[ "$lock_age" -lt "$LOCK_STALE_SECONDS" ]]; then
      return 1
    fi
    echo "[$LOG_PREFIX] lock held by pid=$lock_pid for ${lock_age}s (>${LOCK_STALE_SECONDS}s); force-clearing"
  elif [[ -n "$lock_pid" ]]; then
    echo "[$LOG_PREFIX] lock held by dead pid=$lock_pid; clearing"
  else
    echo "[$LOG_PREFIX] lock exists with no pid file; clearing"
  fi

  rm -rf "$LOCK_DIR"
  if mkdir "$LOCK_DIR" 2>/dev/null; then
    printf '%s\n' "$$" > "$LOCK_PID_FILE"
    return 0
  fi

  return 1
}

if ! acquire_lock; then
  echo "[$LOG_PREFIX] another run is active; exiting"
  exit 0
fi
trap 'rm -rf "$LOCK_DIR" 2>/dev/null || true' EXIT INT TERM

first_seen_file="$STATE_DIR/first_seen_fresh_zero_epoch"
last_kicked_file="$STATE_DIR/last_kicked_epoch"

log() {
  echo "[$LOG_PREFIX] $(date -u '+%Y-%m-%dT%H:%M:%SZ') $*"
}

read_epoch_file() {
  local path="$1"
  if [[ -f "$path" ]]; then
    /usr/bin/awk 'NR == 1 { print $1 }' "$path"
  fi
}

parse_utc_epoch() {
  local iso="$1"
  date -u -j -f "%Y-%m-%dT%H:%M:%SZ" "$iso" "+%s" 2>/dev/null
}

run_kickoff_prompt() {
  "$CODEX" exec \
    --skip-git-repo-check \
    --ephemeral \
    --ignore-user-config \
    --ignore-rules \
    --sandbox read-only \
    --disable plugins \
    --disable apps \
    --disable browser_use \
    --disable browser_use_external \
    --disable computer_use \
    --disable image_generation \
    --disable multi_agent \
    --disable shell_tool \
    --disable unified_exec \
    -m gpt-5.4-mini \
    -c 'model_reasoning_effort="low"' \
    "Reply exactly: pong"
}

codexbar_stderr_file="$STATE_DIR/.codexbar_stderr"
usage_json="$("$CODEXBAR" usage --provider codex --source "$CODEXBAR_SOURCE" --format json --json-only 2>"$codexbar_stderr_file")"
codexbar_status=$?

if [[ $codexbar_status -ne 0 ]]; then
  codexbar_stderr=""
  [[ -s "$codexbar_stderr_file" ]] && codexbar_stderr="$(<"$codexbar_stderr_file")"
  log "codexbar failed (exit=$codexbar_status): stdout='$usage_json' stderr='$codexbar_stderr'"
  exit 0
fi

if [[ -s "$codexbar_stderr_file" ]]; then
  log "codexbar warning: $(<"$codexbar_stderr_file")"
fi

used_percent="$(printf '%s' "$usage_json" | "$JQ" -er '.[0].usage.primary.usedPercent')"
resets_at="$(printf '%s' "$usage_json" | "$JQ" -er '.[0].usage.primary.resetsAt')"
account="$(printf '%s' "$usage_json" | "$JQ" -r '.[0].usage.accountEmail // "unknown"')"

reset_epoch="$(parse_utc_epoch "$resets_at" || true)"
if [[ -z "${reset_epoch:-}" ]]; then
  log "could not parse resetsAt='${resets_at:-<empty>}'; expected YYYY-MM-DDTHH:MM:SSZ"
  exit 0
fi

if ! [[ "$reset_epoch" =~ ^[0-9]+$ ]]; then
  log "reset_epoch not numeric: '${reset_epoch}'"
  exit 0
fi

minutes_until_reset=$(( (${reset_epoch:-0} - ${now_epoch:-0}) / 60 ))
last_kicked="$(read_epoch_file "$last_kicked_file")"

if [[ -n "${last_kicked:-}" && $((now_epoch - last_kicked)) -lt "$SUPPRESS_AFTER_KICK_SECONDS" ]]; then
  log "suppressed after recent kickoff; used=${used_percent}% reset_in=${minutes_until_reset}m account=${account}"
  exit 0
fi

fresh_unused=0
if [[ "$used_percent" == "0" \
  && "$minutes_until_reset" -ge "$FRESH_WINDOW_MINUTES_MIN" \
  && "$minutes_until_reset" -le "$FRESH_WINDOW_MINUTES_MAX" ]]; then
  fresh_unused=1
fi

if [[ "$fresh_unused" -ne 1 ]]; then
  rm -f "$first_seen_file"
  log "not fresh-unused; used=${used_percent}% reset_in=${minutes_until_reset}m account=${account}"
  exit 0
fi

first_seen="$(read_epoch_file "$first_seen_file")"
if [[ -z "${first_seen:-}" ]]; then
  printf '%s\n' "$now_epoch" > "$first_seen_file"
  log "fresh-unused first seen; waiting ${POLL_IDLE_SECONDS}s before kickoff; reset_in=${minutes_until_reset}m account=${account}"
  exit 0
fi

idle_seconds=$((now_epoch - first_seen))
if [[ "$idle_seconds" -lt "$POLL_IDLE_SECONDS" ]]; then
  log "fresh-unused pending; idle=${idle_seconds}s reset_in=${minutes_until_reset}m account=${account}"
  exit 0
fi

log "fresh-unused confirmed after ${idle_seconds}s; running kickoff prompt"
if [[ "$DRY_RUN" == "1" ]]; then
  log "dry-run enabled; would run minimal pong prompt with gpt-5.4-mini"
  exit 0
fi

run_kickoff_prompt
kick_status=$?
if [[ "$kick_status" -eq 0 ]]; then
  printf '%s\n' "$now_epoch" > "$last_kicked_file"
  rm -f "$first_seen_file"
  log "kickoff prompt completed"
else
  log "kickoff prompt failed with exit code $kick_status"
fi

exit 0
