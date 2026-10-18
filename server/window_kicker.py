#!/usr/bin/env python3
"""Linux scheduler for existing subscription CLIs inside the Paseo container."""
import argparse
import datetime as dt
import fcntl
import hashlib
import json
import math
import os
from pathlib import Path
import subprocess
import sys
import time


class CheckFailed(Exception):
    """A safe diagnostic, without provider output or account identity."""


def fingerprint(email):
    if not isinstance(email, str) or "@" not in email:
        raise CheckFailed("account identity unavailable")
    return hashlib.sha256(email.strip().lower().encode()).hexdigest()


def percent(value):
    if isinstance(value, bool) or not isinstance(value, (float, int)):
        raise CheckFailed("invalid usage percentage")
    if not math.isfinite(value) or not 0 <= value <= 100:
        raise CheckFailed("invalid usage percentage")
    return value


def reset_epoch(value):
    if value is None:
        return 0
    if not isinstance(value, str):
        raise CheckFailed("invalid reset timestamp")
    try:
        parsed = dt.datetime.fromisoformat(value.replace("Z", "+00:00"))
        if parsed.tzinfo is None:
            raise ValueError()
        return int(parsed.timestamp())
    except (ValueError, OverflowError):
        raise CheckFailed("invalid reset timestamp") from None


def parse_usage(payload, provider, expected_account):
    if not isinstance(payload, list) or len(payload) != 1:
        raise CheckFailed("expected exactly one provider account")
    row = payload[0]
    if not isinstance(row, dict) or row.get("provider") != provider or row.get("error"):
        raise CheckFailed("provider usage unavailable")
    usage = row.get("usage")
    if not isinstance(usage, dict):
        raise CheckFailed("provider usage unavailable")
    if fingerprint(usage.get("accountEmail")) != expected_account:
        raise CheckFailed("account changed; re-verify migration before enabling kickoff")
    primary, weekly = usage.get("primary"), usage.get("secondary")
    weekly_used = 0
    if weekly is not None:
        if not isinstance(weekly, dict) or weekly.get("windowMinutes") != 10080:
            raise CheckFailed("invalid weekly usage")
        weekly_used = percent(weekly.get("usedPercent"))
        reset_epoch(weekly.get("resetsAt"))
    if primary is None:
        # A successful weekly-only snapshot is not an unused five-hour window.
        if provider == "codex" and weekly is not None:
            return {"has_session": False, "weekly_used": weekly_used}
        raise CheckFailed("five-hour usage unavailable")
    if not isinstance(primary, dict) or primary.get("windowMinutes") != 300:
        raise CheckFailed("unexpected session window")
    return {"has_session": True, "used": percent(primary.get("usedPercent")),
            "reset": reset_epoch(primary.get("resetsAt")), "weekly_used": weekly_used}


def decision(provider, usage, state, now, idle_seconds=600):
    """Mutate debounce state; return a fixed, non-sensitive decision code."""
    if not usage["has_session"]:
        state.pop("pending_since", None)
        return "no-five-hour-window"
    used, reset = usage["used"], usage["reset"]
    fresh_codex = provider == "codex" and used == 0 and 285 <= (reset - now) / 60 <= 315
    expired = 0 < reset <= now
    idle = reset == 0 and used == 0
    if usage["weekly_used"] >= 100 or not (fresh_codex or expired or idle):
        state.pop("pending_since", None)
        return "active-or-limited"
    success = state.get("last_success", 0)
    if success and ((reset == 0 and now - success < 18000)
                    or (reset > 0 and reset <= success)
                    or (fresh_codex and now - success < 16200)):
        state.pop("pending_since", None)
        return "already-kicked"
    if now - state.get("last_attempt", 0) < 900:
        return "attempt-cooldown"
    pending = state.get("pending_since")
    if pending is None or pending > now:
        state["pending_since"] = now
        return "idle-first-seen"
    if now - pending < idle_seconds:
        return "idle-pending"
    return "kick"


class ContainerCLI:
    def __init__(self, config):
        self.config = config

    def command(self, args):
        timeout = self.config.get("command_timeout", 120)
        return ["/usr/bin/docker", "exec", "--user", "paseo", "--workdir", "/tmp",
                self.config.get("container", "paseo"), "timeout", "--kill-after=5s", str(timeout),
                "env", "-u", "ANTHROPIC_API_KEY", "-u", "ANTHROPIC_AUTH_TOKEN",
                "-u", "ANTHROPIC_BASE_URL", "-u", "CLAUDE_CODE_USE_BEDROCK",
                "-u", "CLAUDE_CODE_USE_VERTEX", "-u", "CLAUDE_CODE_USE_FOUNDRY",
                "-u", "CLAUDECODE", "-u", "OPENAI_API_KEY", "-u", "CODEX_API_KEY",
                "-u", "OPENAI_BASE_URL", "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1", *args]

    def run(self, args, include_stderr=False):
        try:
            result = subprocess.run(self.command(args), stdin=subprocess.DEVNULL,
                                    stdout=subprocess.PIPE,
                                    stderr=subprocess.STDOUT if include_stderr else subprocess.DEVNULL,
                                    text=True, timeout=self.config.get("command_timeout", 120) + 10)
        except (OSError, subprocess.TimeoutExpired):
            raise CheckFailed("provider command unavailable or timed out") from None
        if result.returncode:
            raise CheckFailed("provider command failed or timed out")
        return result.stdout

    def usage(self, provider):
        # Claude OAuth works on Linux; CLI /usage probes can hang headlessly.
        source = "oauth" if provider == "claude" else "cli"
        try:
            return json.loads(self.run([self.config["codexbar"], "usage", "--provider", provider,
                                        "--source", source, "--format", "json", "--json-only"]))
        except json.JSONDecodeError:
            raise CheckFailed("invalid provider usage JSON") from None

    def authenticate(self, provider):
        if provider == "claude":
            try:
                status = json.loads(self.run(["claude", "--safe-mode", "--setting-sources", "",
                                               "auth", "status"]))
            except json.JSONDecodeError:
                raise CheckFailed("invalid Claude login status") from None
            if (not isinstance(status, dict) or status.get("loggedIn") is not True
                    or status.get("authMethod") not in ("claude.ai", "oauth_token")
                    or not status.get("subscriptionType")):
                raise CheckFailed("Claude subscription login required")
            if fingerprint(status.get("email")) != self.config["expected_account"]:
                raise CheckFailed("Claude account changed")
        elif "Logged in using ChatGPT" not in self.run(["codex", "login", "status"], include_stderr=True):
            raise CheckFailed("Codex ChatGPT login required")

    def kick(self, provider):
        if provider == "claude":
            args = ["claude", "--safe-mode", "--setting-sources", "", "--print", "--model", "haiku",
                    "--effort", "low", "--tools", "", "--strict-mcp-config", "--mcp-config",
                    '{"mcpServers":{}}', "--disable-slash-commands", "--no-chrome",
                    "--no-session-persistence", "--system-prompt", "Reply exactly: pong",
                    "--output-format", "json", "Reply exactly: pong"]
            try:
                result = json.loads(self.run(args))
            except json.JSONDecodeError:
                raise CheckFailed("invalid Claude kickoff response") from None
            if not isinstance(result, dict) or result.get("is_error") is not False:
                raise CheckFailed("Claude kickoff failed")
            text = result.get("result")
        else:
            args = ["codex", "exec", "--skip-git-repo-check", "--ephemeral", "--ignore-user-config",
                    "--ignore-rules", "--sandbox", "read-only", "--color", "never"]
            for feature in ("plugins", "apps", "browser_use", "browser_use_external", "computer_use",
                            "image_generation", "multi_agent", "shell_tool", "unified_exec"):
                args += ["--disable", feature]
            args += ["-m", "gpt-5.4-mini", "-c", 'model_reasoning_effort="low"', "Reply exactly: pong"]
            text = self.run(args)
        if not isinstance(text, str) or text.strip().lower() != "pong":
            raise CheckFailed("kickoff response did not confirm pong")


def save_state(path, state):
    temporary = path.with_suffix(".tmp")
    temporary.write_text(json.dumps(state) + "\n")
    temporary.replace(path)


def run_once(config, cli, state_path, dry_run=False, now=None):
    live_clock = now is None
    now = int(time.time()) if now is None else now
    state = {}
    if state_path.exists():
        try:
            state = json.loads(state_path.read_text())
            if not isinstance(state, dict) or any(isinstance(v, bool) or not isinstance(v, int) or v < 0
                                                 for v in state.values()):
                raise ValueError()
        except (ValueError, OSError):
            raise CheckFailed("invalid saved state; inspect before resuming") from None
    try:
        usage = parse_usage(cli.usage(config["provider"]), config["provider"], config["expected_account"])
    except CheckFailed:
        state.pop("pending_since", None)
        save_state(state_path, state)
        raise
    action = decision(config["provider"], usage, state, now)
    if action == "kick":
        if dry_run:
            action = "dry-run-would-kick"
        else:
            # Persist attempt before auth/request so failures cannot create a tight retry loop.
            state["last_attempt"] = now
            save_state(state_path, state)
            cli.authenticate(config["provider"])
            cli.kick(config["provider"])
            state["last_success"] = int(time.time()) if live_clock else now
            state.pop("pending_since", None)
            action = "kickoff-completed"
    save_state(state_path, state)
    return action


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--config", required=True, type=Path)
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args()
    os.umask(0o077)
    try:
        config = json.loads(args.config.read_text())
        if config.get("provider") not in ("claude", "codex"):
            raise CheckFailed("invalid provider configuration")
        directory = Path(config["state_dir"])
        directory.mkdir(parents=True, exist_ok=True)
        with (directory / "lock").open("a") as lock:
            try:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                print("another-run-active", flush=True)
                return 0
            print(run_once(config, ContainerCLI(config), directory / "state.json", args.dry_run), flush=True)
        return 0
    except CheckFailed as error:
        print(str(error), file=sys.stderr, flush=True)
        return 1
    except (OSError, ValueError, KeyError, TypeError):
        print("configuration or state error; details withheld", file=sys.stderr, flush=True)
        return 1


if __name__ == "__main__":
    sys.exit(main())
