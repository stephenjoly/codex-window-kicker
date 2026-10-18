"""Offline behavior and lifecycle checks; never invoke a real provider or launchctl."""
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parents[1]


class ClaudeKickerTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.home = Path(self.temp.name)
        self.bin = self.home / "bin"
        self.bin.mkdir()
        self.state = self.home / "state"
        self.state.mkdir()
        self.calls = self.home / "calls"
        self.usage = self.home / "usage.json"
        self.env = dict(os.environ, HOME=str(self.home), RUNTIME_DIR=str(self.home),
                        STATE_DIR=str(self.state), PATH=f"{self.bin}:{os.environ['PATH']}",
                        CALLS=str(self.calls), FIXTURE=str(self.usage),
                        POLL_IDLE_SECONDS="600", COMMAND_TIMEOUT_SECONDS="2",
                        AUTH_JSON=json.dumps({"loggedIn": True, "authMethod": "claude.ai",
                                              "subscriptionType": "team"}),
                        CODEXBAR=str(self.bin / "codexbar"), CLAUDE=str(self.bin / "claude"),
                        JQ=shutil.which("jq"), ANTHROPIC_API_KEY="synthetic-do-not-use")
        self.mock("codexbar", '''#!/bin/zsh
echo "usage $*" >> "$CALLS"
cat "$FIXTURE"
exit ${USAGE_EXIT:-0}
''')
        self.mock("claude", '''#!/bin/zsh
[[ -z "${ANTHROPIC_API_KEY:-}" ]] || exit 99
echo "cli_invocation $*" >> "$CALLS"
if [[ " $* " == *' auth status '* ]]; then
  print -r -- "$AUTH_JSON"
  exit 0
elif [[ "${KICK_SLEEP:-0}" != 0 ]]; then
  sleep "$KICK_SLEEP"
else
  echo '{"is_error":false,"result":"pong"}'
fi
exit ${KICK_EXIT:-0}
''')
        self.mock("launchctl", '''#!/bin/zsh
echo "$*" >> "$CALLS"
if [[ "$1" == print ]]; then exit ${LOADED:-0}; fi
''')
        self.write_usage()

    def mock(self, name, text):
        path = self.bin / name
        path.write_text(text)
        path.chmod(0o755)

    def write_usage(self, *, reset=-60, used=0, weekly=10):
        timestamp = None if reset is None else time.strftime(
            "%Y-%m-%dT%H:%M:%SZ", time.gmtime(time.time() + reset))
        self.usage.write_text(json.dumps([{"provider": "claude", "usage": {
            "primary": {"usedPercent": used, "resetsAt": timestamp, "windowMinutes": 300},
            "secondary": {"usedPercent": weekly}}}]))

    def pending(self):
        (self.state / "first_seen_idle_epoch").write_text(str(int(time.time()) - 610))

    def run_script(self, path="bin/claude-window-kicker.zsh", *args, **env):
        result = subprocess.run(["/bin/zsh", str(ROOT / path), *args],
                                env=dict(self.env, **env), capture_output=True, text=True, timeout=15)
        self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
        return result.stdout

    def call_text(self):
        return self.calls.read_text() if self.calls.exists() else ""

    def test_wait_then_kick_once(self):
        self.assertIn("first seen", self.run_script())
        self.assertIn("pending", self.run_script())
        self.assertNotIn("cli_invocation ", self.call_text())
        self.pending()
        self.assertIn("completed", self.run_script())
        self.assertTrue((self.state / "last_kicked_epoch").exists())
        self.assertIn("already kicked", self.run_script())
        self.assertEqual(self.call_text().count("--print"), 1)
        for flag in ["--safe-mode", "--tools", "--no-session-persistence", "--strict-mcp-config"]:
            self.assertIn(flag, self.call_text())

    def test_future_window_even_zero_cancels_pending(self):
        self.pending()
        self.write_usage(reset=18000)
        self.assertIn("window active", self.run_script())
        self.assertFalse((self.state / "first_seen_idle_epoch").exists())
        self.assertNotIn("cli_invocation ", self.call_text())

    def test_expired_window_with_stale_usage_can_kick(self):
        self.pending()
        self.write_usage(used=100)
        self.assertIn("completed", self.run_script())

    def test_explicit_idle_without_reset(self):
        self.pending()
        self.write_usage(reset=None)
        self.assertIn("completed", self.run_script())

    def test_observed_reset_can_arrive_before_five_hours_since_kick(self):
        # Provider boundaries can round to a clock time. Honor the reported reset.
        (self.state / "last_kicked_epoch").write_text(str(int(time.time()) - 14400))
        self.pending()
        self.assertIn("completed", self.run_script())

    def test_same_stale_reset_never_repeats(self):
        (self.state / "last_kicked_epoch").write_text(str(int(time.time()) - 20000))
        self.write_usage(reset=-21000)
        self.pending()
        self.assertIn("already kicked", self.run_script())
        self.assertNotIn("--print", self.call_text())

    def test_weekly_limit_skips(self):
        self.pending()
        self.write_usage(weekly=100)
        self.assertIn("weekly limit", self.run_script())
        self.assertNotIn("cli_invocation ", self.call_text())

    def test_bad_usage_clears_pending(self):
        for value in ["broken", "[]", '[{"provider":"claude","error":{"code":3}}]',
                      '[{"provider":"claude","usage":{"primary":{}}}]']:
            with self.subTest(value=value):
                self.pending()
                self.usage.write_text(value)
                self.assertIn("invalid", self.run_script())
                self.assertFalse((self.state / "first_seen_idle_epoch").exists())
        self.assertNotIn("cli_invocation ", self.call_text())

    def test_usage_failure_and_dry_run(self):
        self.pending()
        self.assertIn("usage check failed", self.run_script(USAGE_EXIT="1"))
        self.pending()
        self.assertIn("dry-run", self.run_script(DRY_RUN="1"))
        self.assertNotIn("cli_invocation ", self.call_text())
        self.assertFalse((self.state / "last_kicked_epoch").exists())

    def test_kick_failure_cooldown(self):
        self.pending()
        self.assertIn("kickoff failed", self.run_script(KICK_EXIT="1"))
        self.assertFalse((self.state / "last_kicked_epoch").exists())
        self.assertIn("recent attempt", self.run_script())

    def test_non_subscription_skips(self):
        self.pending()
        auth = json.dumps({"loggedIn": True, "authMethod": "api_key"})
        self.assertIn("subscription login required", self.run_script(AUTH_JSON=auth))
        self.assertNotIn("--print", self.call_text())

    def test_timeout_skips_success(self):
        self.pending()
        self.assertIn("timed out", self.run_script(KICK_SLEEP="4"))
        self.assertFalse((self.state / "last_kicked_epoch").exists())

    def test_live_lock_skips(self):
        lock = self.state / "lock"
        lock.mkdir()
        (lock / "pid").write_text(str(os.getpid()))
        self.run_script()
        self.assertEqual(self.call_text(), "")

    def test_lifecycle_isolated_for_each_provider(self):
        # HOME and launchctl are disposable. No live agent is changed.
        for provider in ["claude", "codex"]:
            self.mock(provider, (self.bin / "claude").read_text())
            self.run_script("install.zsh", provider)
            app = provider.title() + "WindowKicker"
            runtime = self.home / "Library/Application Support" / app
            label = f"com.{provider}-window-kicker.agent"
            plist = self.home / "Library/LaunchAgents" / (label + ".plist")
            data = plistlib.loads(plist.read_bytes())
            self.assertEqual(data["Label"], label)
            self.assertEqual(data["StartInterval"], 300)
            self.assertTrue(Path(data["ProgramArguments"][1]).exists())
            control = runtime / f"{provider}-window-kicker-control.zsh"
            for action, loaded, expected in [("status", "0", "enabled"),
                                              ("off", "0", "disabled"),
                                              ("off", "1", "already disabled"),
                                              ("on", "1", "enabled"),
                                              ("on", "0", "restarted")]:
                self.calls.write_text("")
                self.assertIn(expected, self.run_script(str(control), action, LOADED=loaded))
                calls = self.call_text()
                self.assertIn(f"print gui/{os.getuid()}/{label}", calls)
                if action == "off" and loaded == "0":
                    self.assertIn(f"bootout gui/{os.getuid()}/{label}", calls)
                if action == "on" and loaded == "1":
                    self.assertIn(f"bootstrap gui/{os.getuid()}", calls)
                if action == "on":
                    self.assertIn(f"kickstart -k gui/{os.getuid()}/{label}", calls)
                self.assertTrue(plist.exists())
            self.calls.write_text("")
            self.run_script("uninstall.zsh", provider)
            self.assertFalse(plist.exists())
            self.assertTrue(control.exists())
            other = "codex" if provider == "claude" else "claude"
            self.assertNotIn(f"com.{other}-window-kicker", self.call_text())


if __name__ == "__main__":
    unittest.main()
