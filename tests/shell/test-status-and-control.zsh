#!/bin/zsh
set -euo pipefail

ROOT_DIR="${0:A:h:h:h}"
WORKER="$ROOT_DIR/bin/codex-window-kicker.zsh"
CONTROL="$ROOT_DIR/bin/codex-window-kicker-control.zsh"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/codex-window-kicker-tests.XXXXXX")"
trap 'rm -rf "$TEST_ROOT"' EXIT

fail() {
  print -u2 -- "FAIL: $*"
  exit 1
}

assert_contains() {
  local file="$1" expected="$2"
  grep -F -- "$expected" "$file" >/dev/null || fail "expected $file to contain: $expected"
}

assert_valid_status() {
  python3 -m json.tool "$STATUS_FILE" >/dev/null || fail "status is not valid JSON"
  [[ -z "$(find "$STATE_DIR" -maxdepth 1 -name '.status.*.tmp' -print -quit)" ]] || fail "worker left a partial status file"
}

MOCK_BIN="$TEST_ROOT/mock-bin"
mkdir -p "$MOCK_BIN"

cat > "$MOCK_BIN/codexbar" <<'EOF'
#!/bin/zsh
if [[ "${MOCK_CODEXBAR_EXIT:-0}" != 0 ]]; then
  if [[ "${MOCK_CODEXBAR_ESC:-0}" == 1 ]]; then
    print -u2 -- $'mock codexbar failure \e[31m'
  else
    print -u2 -- "mock codexbar failure"
  fi
  exit "$MOCK_CODEXBAR_EXIT"
fi
print -- '{"mock":true}'
EOF

cat > "$MOCK_BIN/jq" <<'EOF'
#!/bin/zsh
[[ "${MOCK_JQ_FAIL:-0}" == 0 ]] || exit 1
case "$*" in
  *usedPercent*) print -- "${MOCK_USAGE_PERCENT:-12}" ;;
  *resetsAt*) print -- "${MOCK_RESET_AT:?MOCK_RESET_AT is required}" ;;
  *accountEmail*) print -- "test@example.invalid" ;;
  *) exit 1 ;;
esac
EOF

cat > "$MOCK_BIN/codex" <<'EOF'
#!/bin/zsh
print -- "$*" >> "${MOCK_CODEX_CALLS:?}"
EOF

cat > "$MOCK_BIN/launchctl" <<'EOF'
#!/bin/zsh
state="${MOCK_LAUNCH_STATE:?}"
print -- "$*" >> "${MOCK_LAUNCH_CALLS:?}"
[[ "${MOCK_LAUNCH_FAIL_ACTION:-}" != "$1" ]] || exit 1
case "$1" in
  print) [[ -f "$state" ]] ;;
  bootstrap) touch "$state" ;;
  bootout) rm -f "$state" ;;
  kickstart) ;;
  *) exit 2 ;;
esac
EOF
chmod +x "$MOCK_BIN/codexbar" "$MOCK_BIN/jq" "$MOCK_BIN/codex" "$MOCK_BIN/launchctl"

RUNTIME_DIR="$TEST_ROOT/runtime"
STATE_DIR="$RUNTIME_DIR/state"
MOCK_CODEX_CALLS="$TEST_ROOT/codex-calls"
export RUNTIME_DIR STATE_DIR MOCK_CODEX_CALLS
export CODEXBAR="$MOCK_BIN/codexbar" JQ="$MOCK_BIN/jq" CODEX="$MOCK_BIN/codex"
export MOCK_RESET_AT="$(date -u -v+120M '+%Y-%m-%dT%H:%M:%SZ')"
export MOCK_USAGE_PERCENT=12

"$WORKER"
STATUS_FILE="$STATE_DIR/status.json"
[[ -f "$STATUS_FILE" ]] || fail "worker did not create status.json"
assert_valid_status
assert_contains "$STATUS_FILE" '"schemaVersion": 1'
assert_contains "$STATUS_FILE" '"enabled": true'
assert_contains "$STATUS_FILE" '"usagePercent": 12'
assert_contains "$STATUS_FILE" '"lastError": null'

# A failed later poll keeps the last valid usage/reset/kickoff data while recording
# a fresh error and poll time.
printf '%s\n' "$(date +%s)" > "$STATE_DIR/last_kicked_epoch"
export MOCK_CODEXBAR_EXIT=7
export MOCK_CODEXBAR_ESC=1
"$WORKER"
assert_contains "$STATUS_FILE" '"usagePercent": 12'
assert_contains "$STATUS_FILE" "\"resetAt\": \"$MOCK_RESET_AT\""
assert_contains "$STATUS_FILE" '"lastKickoffAt": "'
assert_contains "$STATUS_FILE" '"lastError": "codexbar failed (exit=7)'
assert_valid_status
unset MOCK_CODEXBAR_EXIT
unset MOCK_CODEXBAR_ESC

# A malformed usage response follows the same preservation path.
export MOCK_JQ_FAIL=1
"$WORKER"
assert_contains "$STATUS_FILE" '"usagePercent": 12'
assert_contains "$STATUS_FILE" '"lastError": "could not read primary five-hour usage percentage'
assert_valid_status
unset MOCK_JQ_FAIL

# Missing dependencies also publish an error document without discarding data.
CODEX="" "$WORKER"
assert_contains "$STATUS_FILE" '"usagePercent": 12'
assert_contains "$STATUS_FILE" '"lastError": "missing dependency;'
assert_valid_status

# Dry checks report the observed poll but do not create qualification state or run
# codex. The zero-percent, five-hour-window input would qualify in a normal poll.
rm -f "$STATE_DIR/first_seen_fresh_zero_epoch" "$MOCK_CODEX_CALLS"
export MOCK_USAGE_PERCENT=0
export MOCK_RESET_AT="$(date -u -v+300M '+%Y-%m-%dT%H:%M:%SZ')"
DRY_RUN=1 "$WORKER"
[[ ! -e "$STATE_DIR/first_seen_fresh_zero_epoch" ]] || fail "dry check changed qualification state"
[[ ! -e "$MOCK_CODEX_CALLS" ]] || fail "dry check invoked codex"
assert_contains "$STATUS_FILE" '"usagePercent": 0'
assert_contains "$STATUS_FILE" '"lastError": null'

# Mocked launchctl exercises enable, disable, and their status-file reconciliation
# without using the host's launchd service.
TEST_HOME="$TEST_ROOT/home"
mkdir -p "$TEST_HOME/Library/LaunchAgents"
touch "$TEST_HOME/Library/LaunchAgents/com.codex-window-kicker.agent.plist"
MOCK_LAUNCH_STATE="$TEST_ROOT/launch-loaded"
MOCK_LAUNCH_CALLS="$TEST_ROOT/launch-calls"
export MOCK_LAUNCH_STATE MOCK_LAUNCH_CALLS

HOME="$TEST_HOME" PATH="$MOCK_BIN:$PATH" "$CONTROL" on
assert_contains "$STATUS_FILE" '"enabled": true'
assert_contains "$MOCK_LAUNCH_CALLS" 'bootstrap gui/'
assert_contains "$MOCK_LAUNCH_CALLS" 'kickstart -k gui/'

HOME="$TEST_HOME" PATH="$MOCK_BIN:$PATH" "$CONTROL" on > "$TEST_ROOT/on-already-enabled.out"
assert_contains "$TEST_ROOT/on-already-enabled.out" 'already enabled and was restarted'
assert_contains "$STATUS_FILE" '"enabled": true'

HOME="$TEST_HOME" PATH="$MOCK_BIN:$PATH" "$CONTROL" off
assert_contains "$STATUS_FILE" '"enabled": false'
assert_contains "$STATUS_FILE" '"usagePercent": 0'
assert_contains "$MOCK_LAUNCH_CALLS" 'bootout gui/'

HOME="$TEST_HOME" PATH="$MOCK_BIN:$PATH" "$CONTROL" off
assert_contains "$STATUS_FILE" '"enabled": false'

# Failed launchctl actions leave the status unchanged.
export MOCK_LAUNCH_FAIL_ACTION=bootstrap
if HOME="$TEST_HOME" PATH="$MOCK_BIN:$PATH" "$CONTROL" on; then
  fail "control on succeeded when bootstrap failed"
fi
assert_contains "$STATUS_FILE" '"enabled": false'
unset MOCK_LAUNCH_FAIL_ACTION

HOME="$TEST_HOME" PATH="$MOCK_BIN:$PATH" "$CONTROL" on
assert_contains "$STATUS_FILE" '"enabled": true'
export MOCK_LAUNCH_FAIL_ACTION=bootout
if HOME="$TEST_HOME" PATH="$MOCK_BIN:$PATH" "$CONTROL" off; then
  fail "control off succeeded when bootout failed"
fi
assert_contains "$STATUS_FILE" '"enabled": true'
unset MOCK_LAUNCH_FAIL_ACTION

print -- "shell status/control tests passed"
