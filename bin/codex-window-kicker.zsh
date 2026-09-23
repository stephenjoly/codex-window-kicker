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
now_iso="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"

status_file="$STATE_DIR/status.json"
enabled_state_file="$STATE_DIR/enabled"
usage_percent_file="$STATE_DIR/last_usage_percent"
reset_at_file="$STATE_DIR/last_reset_at"

read_text_file() {
  local path="$1"
  [[ -f "$path" ]] && /usr/bin/awk 'NR == 1 { print; exit }' "$path"
}

read_epoch_file() {
  local path="$1"
  [[ -f "$path" ]] && /usr/bin/awk 'NR == 1 { print $1; exit }' "$path"
}

epoch_to_utc_iso() {
  local epoch="$1"
  [[ "$epoch" =~ ^[0-9]+$ ]] || return 1
  date -u -r "$epoch" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null
}

json_string() {
  local value="$1"
  # Command errors can include terminal escape sequences. JSON permits only the
  # control characters handled below, so discard the remaining control bytes.
  value="$(printf '%s' "$value" | /usr/bin/tr -d '\001-\010\013\014\016-\037')"
  value="${value//\\/\\\\}"
  value="${value//\"/\\\"}"
  value="${value//$'\n'/\\n}"
  value="${value//$'\r'/\\r}"
  value="${value//$'\t'/\\t}"
  printf '"%s"' "$value"
}

json_nullable_string() {
  [[ -n "${1:-}" ]] && json_string "$1" || printf 'null'
}

json_nullable_number() {
  local value="${1:-}"
  [[ "$value" =~ ^-?([0-9]+)(\.[0-9]+)?$ ]] && printf '%s' "$value" || printf 'null'
}

read_status_enabled() {
  [[ -f "$status_file" ]] || { printf 'true'; return 0; }
  local enabled
  enabled="$(/usr/bin/awk -F: '/"enabled"[[:space:]]*:/ { gsub(/[[:space:],]/, "", $2); print $2; exit }' "$status_file" 2>/dev/null)"
  [[ "$enabled" == "true" || "$enabled" == "false" ]] && printf '%s' "$enabled" || printf 'true'
}

read_enabled_state() {
  local enabled="$(read_text_file "$enabled_state_file")"
  if [[ "$enabled" == "true" || "$enabled" == "false" ]]; then
    printf '%s' "$enabled"
  else
    read_status_enabled
  fi
}

# Readers either see the previous complete file or this complete replacement.
write_status() {
  local enabled="$1" last_poll_at="$2" usage_percent="$3" reset_at="$4" last_kickoff_at="$5" last_error="$6"
  local temporary="$STATE_DIR/.status.$$.tmp"
  # A control-off request is durable in state/enabled before launchctl stops the
  # agent. Re-read it for every write so an in-flight prompt cannot restore true.
  enabled="$(read_enabled_state)"
  (
    umask 077
    {
      printf '{\n'
      printf '  "schemaVersion": 1,\n'
      printf '  "enabled": %s,\n' "$enabled"
      printf '  "lastPollAt": %s,\n' "$(json_nullable_string "$last_poll_at")"
      printf '  "usagePercent": %s,\n' "$(json_nullable_number "$usage_percent")"
      printf '  "resetAt": %s,\n' "$(json_nullable_string "$reset_at")"
      printf '  "lastKickoffAt": %s,\n' "$(json_nullable_string "$last_kickoff_at")"
      printf '  "lastError": %s\n' "$(json_nullable_string "$last_error")"
      printf '}\n'
    } >| "$temporary"
    mv -f "$temporary" "$status_file"
  ) || {
    rm -f "$temporary" 2>/dev/null || true
    return 1
  }
}

status_enabled="$(read_enabled_state)"
[[ "$DRY_RUN" == "1" ]] || status_enabled=true
last_usage_percent="$(read_text_file "$usage_percent_file")"
last_reset_at="$(read_text_file "$reset_at_file")"

write_error_status() {
  local message="$1"
  local prior_kicked="$(read_epoch_file "$STATE_DIR/last_kicked_epoch")"
  local prior_kickoff_at="$(epoch_to_utc_iso "$prior_kicked" || true)"
  write_status "$status_enabled" "$now_iso" "$last_usage_percent" "$last_reset_at" "$prior_kickoff_at" "$message"
}

write_poll_status() {
  local used_percent="$1" resets_at="$2"
  local prior_kicked="$(read_epoch_file "$STATE_DIR/last_kicked_epoch")"
  local prior_kickoff_at="$(epoch_to_utc_iso "$prior_kicked" || true)"
  printf '%s\n' "$used_percent" >| "$usage_percent_file"
  printf '%s\n' "$resets_at" >| "$reset_at_file"
  last_usage_percent="$used_percent"
  last_reset_at="$resets_at"
  write_status "$status_enabled" "$now_iso" "$used_percent" "$resets_at" "$prior_kickoff_at" ""
}

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
  dependency_error="missing dependency; codexbar=${CODEXBAR:-missing} codex=${CODEX:-missing} jq=${JQ:-missing}"
  echo "[$LOG_PREFIX] $dependency_error"
  write_error_status "$dependency_error"
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
  echo "[$LOG_PREFIX] $(date '+%Y-%m-%dT%H:%M:%S%z') $*"
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
  error="codexbar failed (exit=$codexbar_status): stdout='$usage_json' stderr='$codexbar_stderr'"
  log "$error"
  write_error_status "$error"
  exit 0
fi

if [[ -s "$codexbar_stderr_file" ]]; then
  log "codexbar warning: $(<"$codexbar_stderr_file")"
fi

if ! used_percent="$(printf '%s' "$usage_json" | "$JQ" -er '.[0].usage.primary.usedPercent' 2>/dev/null)"; then
  error="could not read primary five-hour usage percentage from codexbar response"
  log "$error"
  write_error_status "$error"
  exit 0
fi

if ! resets_at="$(printf '%s' "$usage_json" | "$JQ" -er '.[0].usage.primary.resetsAt' 2>/dev/null)"; then
  error="could not read primary five-hour reset time from codexbar response"
  log "$error"
  write_error_status "$error"
  exit 0
fi

if ! [[ "$used_percent" =~ ^-?([0-9]+)(\.[0-9]+)?$ ]]; then
  error="primary five-hour usage percentage is not numeric: '$used_percent'"
  log "$error"
  write_error_status "$error"
  exit 0
fi

account="$(printf '%s' "$usage_json" | "$JQ" -r '.[0].usage.accountEmail // "unknown"' 2>/dev/null || printf 'unknown')"

reset_epoch="$(parse_utc_epoch "$resets_at" || true)"
if [[ -z "${reset_epoch:-}" ]]; then
  error="could not parse resetsAt='${resets_at:-<empty>}'; expected YYYY-MM-DDTHH:MM:SSZ"
  log "$error"
  write_error_status "$error"
  exit 0
fi

if ! [[ "$reset_epoch" =~ ^[0-9]+$ ]]; then
  error="reset_epoch not numeric: '${reset_epoch}'"
  log "$error"
  write_error_status "$error"
  exit 0
fi

minutes_until_reset=$(( (${reset_epoch:-0} - ${now_epoch:-0}) / 60 ))
last_kicked="$(read_epoch_file "$last_kicked_file")"

# Dry checks only query and publish the poll result. They never touch
# qualification state or invoke the kickoff prompt.
if [[ "$DRY_RUN" == "1" ]]; then
  write_poll_status "$used_percent" "$resets_at"
  log "dry check; used=${used_percent}% reset_in=${minutes_until_reset}m account=${account}"
  exit 0
fi

if [[ -n "${last_kicked:-}" && $((now_epoch - last_kicked)) -lt "$SUPPRESS_AFTER_KICK_SECONDS" ]]; then
  log "suppressed after recent kickoff; used=${used_percent}% reset_in=${minutes_until_reset}m account=${account}"
  write_poll_status "$used_percent" "$resets_at"
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
  write_poll_status "$used_percent" "$resets_at"
  exit 0
fi

first_seen="$(read_epoch_file "$first_seen_file")"
if [[ -z "${first_seen:-}" ]]; then
  printf '%s\n' "$now_epoch" > "$first_seen_file"
  log "fresh-unused first seen; waiting ${POLL_IDLE_SECONDS}s before kickoff; reset_in=${minutes_until_reset}m account=${account}"
  write_poll_status "$used_percent" "$resets_at"
  exit 0
fi

idle_seconds=$((now_epoch - first_seen))
if [[ "$idle_seconds" -lt "$POLL_IDLE_SECONDS" ]]; then
  log "fresh-unused pending; idle=${idle_seconds}s reset_in=${minutes_until_reset}m account=${account}"
  write_poll_status "$used_percent" "$resets_at"
  exit 0
fi

log "fresh-unused confirmed after ${idle_seconds}s; running kickoff prompt"
write_poll_status "$used_percent" "$resets_at"
run_kickoff_prompt
kick_status=$?
if [[ "$kick_status" -eq 0 ]]; then
  printf '%s\n' "$now_epoch" > "$last_kicked_file"
  rm -f "$first_seen_file"
  last_kickoff_at="$(epoch_to_utc_iso "$now_epoch" || true)"
  write_status "$status_enabled" "$now_iso" "$used_percent" "$resets_at" "$last_kickoff_at" ""
  log "kickoff prompt completed"
else
  error="kickoff prompt failed with exit code $kick_status"
  write_status "$status_enabled" "$now_iso" "$used_percent" "$resets_at" "$(epoch_to_utc_iso "$last_kicked" || true)" "$error"
  log "$error"
fi

exit 0
