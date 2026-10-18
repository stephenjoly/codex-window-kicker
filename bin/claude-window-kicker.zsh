#!/bin/zsh
set -u
umask 077

RUNTIME_DIR="${RUNTIME_DIR:-$HOME/Library/Application Support/ClaudeWindowKicker}"
STATE_DIR="${STATE_DIR:-$RUNTIME_DIR/state}"
LOG_FILE="${LOG_FILE:-$RUNTIME_DIR/claude-window-kicker.log}"
POLL_IDLE_SECONDS="${POLL_IDLE_SECONDS:-600}"
CODEXBAR_SOURCE="${CODEXBAR_SOURCE:-auto}"
DRY_RUN="${DRY_RUN:-0}"
COMMAND_TIMEOUT_SECONDS="${COMMAND_TIMEOUT_SECONDS:-120}"

CODEXBAR="${CODEXBAR:-$(command -v codexbar)}"
CLAUDE="${CLAUDE:-$(command -v claude)}"
JQ="${JQ:-$(command -v jq)}"
mkdir -p "$STATE_DIR"

log() { echo "[claude-window-kicker] $(date '+%Y-%m-%dT%H:%M:%S%z') $*"; }
if [[ -z "$CODEXBAR" || -z "$CLAUDE" || -z "$JQ" ]]; then
  log "missing dependency; requires codexbar, claude, and jq"
  exit 0
fi

# Never clear a live lock: a slow request must not cause a second kickoff.
LOCK_DIR="$STATE_DIR/lock"
if ! mkdir "$LOCK_DIR" 2>/dev/null; then
  lock_pid=""
  [[ -f "$LOCK_DIR/pid" ]] && lock_pid="$(<"$LOCK_DIR/pid")"
  if [[ "$lock_pid" == <-> ]] && ! kill -0 "$lock_pid" 2>/dev/null; then
    rm -f "$LOCK_DIR/pid"
    rmdir "$LOCK_DIR" 2>/dev/null || exit 0
    mkdir "$LOCK_DIR" 2>/dev/null || exit 0
  else
    exit 0
  fi
fi
echo $$ > "$LOCK_DIR/pid"
child_pid=""
timer_pid=""
cleanup() {
  [[ -n "$child_pid" ]] && kill "$child_pid" 2>/dev/null
  [[ -n "$timer_pid" ]] && kill "$timer_pid" 2>/dev/null
  rm -f "$LOCK_DIR/pid"
  rmdir "$LOCK_DIR" 2>/dev/null
  return 0
}
trap cleanup EXIT
trap 'exit 1' INT TERM

if [[ -f "$LOG_FILE" ]] && (( $(wc -l < "$LOG_FILE") > 10000 )); then
  tail -n 5000 "$LOG_FILE" > "$STATE_DIR/log-tail"
  cat "$STATE_DIR/log-tail" >| "$LOG_FILE"
  rm -f "$STATE_DIR/log-tail"
fi

bounded() {
  "$@" &
  child_pid=$!
  ( sleep "$COMMAND_TIMEOUT_SECONDS"; kill "$child_pid" 2>/dev/null ) &
  timer_pid=$!
  wait "$child_pid"
  local result=$?
  kill "$timer_pid" 2>/dev/null
  wait "$timer_pid" 2>/dev/null
  child_pid=""
  timer_pid=""
  return "$result"
}

read_epoch() {
  local value=""
  [[ -f "$1" ]] && value="$(<"$1")"
  [[ "$value" == <-> ]] && print -r -- "$value" || print 0
}

pending="$STATE_DIR/first_seen_idle_epoch"
usage_file="$STATE_DIR/.usage.json"
# Do not retain raw provider errors or account identity in logs/state.
if ! bounded "$CODEXBAR" usage --provider claude --source "$CODEXBAR_SOURCE" \
  --format json --json-only > "$usage_file" 2>/dev/null; then
  rm -f "$usage_file" "$pending"
  log "usage check failed; skipping (check CodexBar Claude login/source)"
  exit 0
fi
usage_fields="$("$JQ" -er '
  if type != "array" or length != 1 then error("unexpected accounts") else .[0] end
  | select(.provider == "claude" and .error == null)
  | .usage | select(.primary | type == "object")
  | .primary as $p
  | select(($p.usedPercent | type) == "number" and $p.usedPercent >= 0 and $p.usedPercent <= 100)
  | select($p.windowMinutes == 300)
  | select(.secondary == null or ((.secondary.usedPercent | type) == "number"
      and .secondary.usedPercent >= 0 and .secondary.usedPercent <= 100))
  | (if $p.resetsAt == null then 0 else
       $p.resetsAt | sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601 end) as $reset
  | [.primary.usedPercent, $reset, (.secondary.usedPercent // 0)] | @tsv
' "$usage_file" 2>/dev/null)"
rm -f "$usage_file"
if [[ -z "$usage_fields" ]]; then
  rm -f "$pending"
  log "usage unavailable or invalid; skipping (check CodexBar Claude login/source)"
  exit 0
fi
IFS=$'\t' read -r used reset_epoch weekly_used <<< "$usage_fields"
now_epoch="$(date +%s)"
last_kicked="$(read_epoch "$STATE_DIR/last_kicked_epoch")"
last_attempt="$(read_epoch "$STATE_DIR/last_attempt_epoch")"

# A future reset means a window already runs, even when usage rounds to zero.
# Expired windows can retain their old usage; explicit zero with no reset is idle.
if (( reset_epoch > now_epoch || (reset_epoch == 0 && used != 0) || weekly_used >= 100 )); then
  rm -f "$pending"
  log "window active or weekly limit reached; used=${used}%"
  exit 0
fi
if (( (reset_epoch == 0 && now_epoch - last_kicked < 18000) || (reset_epoch > 0 && reset_epoch <= last_kicked) )); then
  rm -f "$pending"
  log "already kicked this window; skipping"
  exit 0
fi
if (( now_epoch - last_attempt < 900 )); then
  log "recent attempt; waiting before retry"
  exit 0
fi
first_seen="$(read_epoch "$pending")"
if (( first_seen == 0 )); then
  echo "$now_epoch" > "$pending"
  log "idle window first seen; waiting ${POLL_IDLE_SECONDS}s"
  exit 0
fi
if (( now_epoch - first_seen < POLL_IDLE_SECONDS )); then
  log "idle window pending"
  exit 0
fi
if [[ "$DRY_RUN" == 1 ]]; then
  log "dry-run: would send one minimal Claude Haiku pong prompt"
  exit 0
fi

# Preserve subscription auth, exclude API/third-party billing and nested-session state.
subscription_claude() {
  bounded env -u ANTHROPIC_API_KEY -u ANTHROPIC_AUTH_TOKEN -u ANTHROPIC_BASE_URL \
    -u CLAUDE_CODE_USE_BEDROCK -u CLAUDE_CODE_USE_VERTEX -u CLAUDE_CODE_USE_FOUNDRY \
    -u CLAUDECODE CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1 \
    "$CLAUDE" --safe-mode --setting-sources '' "$@"
}
if ! subscription_claude auth status > "$STATE_DIR/.auth.json" 2>/dev/null; then
  rm -f "$STATE_DIR/.auth.json"
  log "Claude subscription login unavailable; skipping"
  exit 0
fi
if ! "$JQ" -e '.loggedIn == true and (.authMethod == "claude.ai" or .authMethod == "oauth_token")
  and (.subscriptionType | type == "string" and length > 0)' "$STATE_DIR/.auth.json" >/dev/null 2>&1; then
  rm -f "$STATE_DIR/.auth.json"
  log "Claude subscription login required; skipping"
  exit 0
fi
rm -f "$STATE_DIR/.auth.json"
echo "$now_epoch" > "$STATE_DIR/last_attempt_epoch"
if subscription_claude --print --model haiku --effort low \
  --tools '' --strict-mcp-config --mcp-config '{"mcpServers":{}}' \
  --disable-slash-commands --no-chrome --no-session-persistence \
  --system-prompt 'Reply exactly: pong' --output-format json 'Reply exactly: pong' \
  > "$STATE_DIR/.response.json" 2>/dev/null \
  && "$JQ" -e '.is_error == false and (.result | ascii_downcase | gsub("^\\s+|\\s+$"; "") == "pong")' \
    "$STATE_DIR/.response.json" >/dev/null 2>&1; then
  echo "$(date +%s)" > "$STATE_DIR/last_kicked_epoch"
  rm -f "$pending"
  log "kickoff prompt completed"
else
  log "kickoff failed or timed out; retry no sooner than 15 minutes"
fi
rm -f "$STATE_DIR/.response.json"
