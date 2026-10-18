"""Both-provider Linux behavior tests; no real Docker, credentials, or prompts."""
import datetime as dt
import importlib.util
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

SPEC = importlib.util.spec_from_file_location(
    "server_kicker", Path(__file__).resolve().parents[1] / "server/window_kicker.py")
kicker = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(kicker)
EMAIL = "synthetic@example.test"
BINDING = kicker.fingerprint(EMAIL)
NOW = 2_000_000_000


def fixture(provider, used=0, reset=NOW - 60, weekly=30, primary=True):
    timestamp = None if reset is None else dt.datetime.fromtimestamp(reset, dt.timezone.utc).isoformat()
    return [{"provider": provider, "usage": {"accountEmail": EMAIL,
             "primary": {"windowMinutes": 300, "usedPercent": used, "resetsAt": timestamp} if primary else None,
             "secondary": {"windowMinutes": 10080, "usedPercent": weekly,
                           "resetsAt": "2033-05-25T10:00:00Z"}}}]


class FakeCLI:
    def __init__(self, payload):
        self.payload = payload
        self.kicks = 0
        self.auths = 0
        self.usage_error = self.kick_error = self.auth_error = False

    def usage(self, provider):
        if self.usage_error:
            raise kicker.CheckFailed("usage failed")
        return self.payload

    def authenticate(self, provider):
        self.auths += 1
        if self.auth_error:
            raise kicker.CheckFailed("auth failed")

    def kick(self, provider):
        self.kicks += 1
        if self.kick_error:
            raise kicker.CheckFailed("kick failed")


class ServerKickerTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.path = Path(self.temp.name) / "state.json"

    def config(self, provider):
        return {"provider": provider, "expected_account": BINDING,
                "codexbar": "/pinned/codexbar", "command_timeout": 2}

    def run_once(self, provider, cli, now=NOW, dry_run=False):
        return kicker.run_once(self.config(provider), cli, self.path, dry_run, now)

    def test_both_providers_wait_then_kick_once(self):
        for provider in ("claude", "codex"):
            with self.subTest(provider=provider):
                self.path.unlink(missing_ok=True)
                cli = FakeCLI(fixture(provider))
                self.assertEqual(self.run_once(provider, cli), "idle-first-seen")
                self.assertEqual(self.run_once(provider, cli, NOW + 300), "idle-pending")
                self.assertEqual(self.run_once(provider, cli, NOW + 600), "kickoff-completed")
                self.assertEqual(self.run_once(provider, cli, NOW + 20000), "already-kicked")
                self.assertEqual(cli.kicks, 1)

    def test_future_rounded_zero_claude_is_active(self):
        self.path.write_text(json.dumps({"pending_since": NOW - 610}))
        cli = FakeCLI(fixture("claude", reset=NOW + 18000))
        self.assertEqual(self.run_once("claude", cli), "active-or-limited")
        self.assertNotIn("pending_since", json.loads(self.path.read_text()))
        self.assertEqual(cli.kicks, 0)

    def test_codex_fresh_sliding_zero_window(self):
        cli = FakeCLI(fixture("codex", reset=NOW + 18000))
        self.assertEqual(self.run_once("codex", cli), "idle-first-seen")
        cli.payload = fixture("codex", reset=NOW + 18600)
        self.assertEqual(self.run_once("codex", cli, NOW + 600), "kickoff-completed")
        cli.payload = fixture("codex", reset=NOW + 18900)
        self.assertEqual(self.run_once("codex", cli, NOW + 900), "already-kicked")

    def test_weekly_only_codex_is_successful_noop(self):
        cli = FakeCLI(fixture("codex", primary=False))
        self.assertEqual(self.run_once("codex", cli), "no-five-hour-window")
        self.assertEqual(cli.kicks, 0)
        with self.assertRaises(kicker.CheckFailed):
            kicker.parse_usage(fixture("claude", primary=False), "claude", BINDING)

    def test_expired_stale_usage_and_missing_reset_zero(self):
        for used, reset in [(100, NOW - 1), (0, None)]:
            with self.subTest(used=used, reset=reset):
                self.path.write_text(json.dumps({"pending_since": NOW - 610}))
                cli = FakeCLI(fixture("claude", used=used, reset=reset))
                self.assertEqual(self.run_once("claude", cli), "kickoff-completed")

    def test_reported_reset_can_be_less_than_five_hours_after_kick(self):
        self.path.write_text(json.dumps({"last_success": NOW - 14400, "pending_since": NOW - 610}))
        self.assertEqual(self.run_once("claude", FakeCLI(fixture("claude"))), "kickoff-completed")

    def test_weekly_exhaustion_never_kicks(self):
        cli = FakeCLI(fixture("claude", weekly=100))
        self.assertEqual(self.run_once("claude", cli), "active-or-limited")
        self.assertEqual(cli.kicks, 0)

    def test_account_switch_and_malformed_usage_fail_closed(self):
        bad_payloads = [[], {}, [{"provider": "claude", "error": {"code": 3}}],
                        fixture("claude", used="0"), fixture("claude", used=True),
                        fixture("claude", used=float("nan")), fixture("claude", weekly="bad")]
        other = fixture("claude")
        other[0]["usage"]["accountEmail"] = "other@example.test"
        bad_payloads.append(other)
        bad_date = fixture("claude")
        bad_date[0]["usage"]["primary"]["resetsAt"] = "bad"
        bad_payloads.append(bad_date)
        for payload in bad_payloads:
            with self.subTest(payload=payload):
                self.path.write_text(json.dumps({"pending_since": NOW - 610}))
                cli = FakeCLI(payload)
                with self.assertRaises(kicker.CheckFailed):
                    self.run_once("claude", cli)
                self.assertEqual(cli.kicks, 0)
                self.assertNotIn("pending_since", json.loads(self.path.read_text()))

    def test_usage_failure_cancels_pending(self):
        self.path.write_text(json.dumps({"pending_since": NOW - 610}))
        cli = FakeCLI(fixture("claude"))
        cli.usage_error = True
        with self.assertRaises(kicker.CheckFailed):
            self.run_once("claude", cli)
        self.assertNotIn("pending_since", json.loads(self.path.read_text()))

    def test_auth_and_kick_failure_apply_cooldown(self):
        for failure in ("auth_error", "kick_error"):
            self.path.write_text(json.dumps({"pending_since": NOW - 610}))
            cli = FakeCLI(fixture("claude"))
            setattr(cli, failure, True)
            with self.assertRaises(kicker.CheckFailed):
                self.run_once("claude", cli)
            self.assertNotIn("last_success", json.loads(self.path.read_text()))
            self.assertEqual(self.run_once("claude", cli, NOW + 300), "attempt-cooldown")

    def test_dry_run_never_authenticates_or_records_success(self):
        self.path.write_text(json.dumps({"pending_since": NOW - 610}))
        cli = FakeCLI(fixture("claude"))
        self.assertEqual(self.run_once("claude", cli, dry_run=True), "dry-run-would-kick")
        self.assertEqual(cli.kicks, 0)
        self.assertEqual(cli.auths, 0)
        self.assertNotIn("last_success", json.loads(self.path.read_text()))

    def test_corrupt_state_never_resets_duplicate_protection(self):
        self.path.write_text('{"last_success":"broken"}')
        with self.assertRaises(kicker.CheckFailed):
            self.run_once("claude", FakeCLI(fixture("claude")))

    def test_backend_timeout_and_isolation(self):
        backend = kicker.ContainerCLI(self.config("claude"))
        command = backend.command(["claude", "--print", "pong"])
        self.assertIn("timeout", command)
        self.assertIn("--kill-after=5s", command)
        self.assertIn("ANTHROPIC_API_KEY", command)
        self.assertIn("OPENAI_API_KEY", command)
        with patch.object(kicker.subprocess, "run", side_effect=subprocess.TimeoutExpired(command, 1)):
            with self.assertRaisesRegex(kicker.CheckFailed, "timed out"):
                backend.run(["claude"])
        with patch.object(backend, "run", return_value='{"is_error":false,"result":"pong"}') as run:
            backend.kick("claude")
            args = run.call_args.args[0]
            for flag in ("--safe-mode", "--tools", "--no-session-persistence", "--strict-mcp-config"):
                self.assertIn(flag, args)
        with patch.object(backend, "run", return_value="pong") as run:
            backend.kick("codex")
            args = run.call_args.args[0]
            self.assertIn("--ignore-user-config", args)
            self.assertIn("--ignore-rules", args)
            self.assertIn("--ephemeral", args)

    def test_codex_login_stderr_is_captured_without_logging(self):
        backend = kicker.ContainerCLI(self.config("codex"))
        with patch.object(backend, "run", return_value="Logged in using ChatGPT") as run:
            backend.authenticate("codex")
            self.assertTrue(run.call_args.kwargs["include_stderr"])


if __name__ == "__main__":
    unittest.main()
