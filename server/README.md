# Linux server window kickers

The vm-dev installation owns both kickoff schedules. The MacBook LaunchAgents remain installed but disabled. Server operation does not depend on the laptop being awake or connected.

## Runtime

- Host: vm-dev, user `stephen`; systemd user timers with linger enabled.
- Units: `window-kicker@claude.timer`, `window-kicker@codex.timer`.
- Runner: `~/.local/share/window-kicker/window_kicker.py`.
- Config: `~/.config/window-kicker/{claude,codex}.json`.
- Independent state: `~/.local/state/window-kicker/{claude,codex}/state.json`.
- Provider CLIs and CodexBar execute as user `paseo` inside the existing `paseo` container. The container and network must be available.
- CodexBar is pinned to the official Linux musl x86_64 release v0.77.0, verified against GitHub's published SHA-256 digest. Its binary/resources live in the persistent container home under `.local/share/window-kicker/vendor/codexbar/v0.77.0/`.

Each timer checks five minutes after its previous execution finishes. Eligible windows wait ten minutes before a minimal prompt. Claude uses Haiku; Codex uses gpt-5.4-mini. Both run without tools, MCP/user customizations, or saved sessions. API-key billing overrides are removed. Existing CLI subscription authentication is verified before sending a prompt.

Claude uses CodexBar's OAuth source. A future reset means the session already runs, including when usage rounds to zero. Codex uses its CLI RPC source and supports both expired windows and the original fresh, unused five-hour detection. Successful weekly-only Codex responses log `no-five-hour-window` and never trigger a prompt. Missing, malformed, failed, or wrong-account usage is never inferred to be idle.

Account-email SHA-256 bindings prevent a later login switch from silently starting prompts on a different account. Bindings are not credentials. State stores debounce and attempt/success timestamps only; raw responses, account emails, and credentials are not logged or saved. Failed attempts wait fifteen minutes before retry; the same observed expired boundary is not kicked twice. Existing Mac success timestamps were preserved at cutover.

## Status and logs

On vm-dev:

```sh
systemctl --user list-timers --all 'window-kicker@*'
systemctl --user show window-kicker@claude.service window-kicker@codex.service -p Result -p ExecMainStatus
journalctl _SYSTEMD_USER_UNIT=window-kicker@claude.service -n 20 --no-pager
journalctl _SYSTEMD_USER_UNIT=window-kicker@codex.service -n 20 --no-pager
```

The explicit journal filter works on vm-dev even when `journalctl --user` returns no entries.

Normal outcomes: `active-or-limited`, `idle-first-seen`, `idle-pending`, `already-kicked`, `attempt-cooldown`, `kickoff-completed`, and `no-five-hour-window`. Usage/authentication failures return nonzero so systemd marks them visible; the timer retries later. Account changes and corrupt saved state require inspection.

Read live usage without spending a prompt:

```sh
python3 ~/.local/share/window-kicker/window_kicker.py --config ~/.config/window-kicker/claude.json --dry-run
python3 ~/.local/share/window-kicker/window_kicker.py --config ~/.config/window-kicker/codex.json --dry-run
```

Dry-run preserves normal waiting checks but never authenticates for a kickoff, sends a prompt, or records success. Do not clear success/attempt state to test a prompt.

## Disable, resume, and rollback

Stop both timers and any in-progress checks:

```sh
systemctl --user disable --now window-kicker@claude.timer window-kicker@codex.timer
systemctl --user stop window-kicker@claude.service window-kicker@codex.service
```

Resume on the server:

```sh
systemctl --user enable --now window-kicker@claude.timer window-kicker@codex.timer
```

For rollback to the laptop, stop the server units first, then run these on the MacBook:

```sh
"$HOME/Library/Application Support/ClaudeWindowKicker/claude-window-kicker-control.zsh" on
"$HOME/Library/Application Support/CodexWindowKicker/codex-window-kicker-control.zsh" on
```

Local jobs remain the original installations; troubleshoot any local usage-reading errors before relying on them. Disabling either installation preserves files and state.

## Reinstall or update

1. Deploy these source files to `~/.local/share/window-kicker/source/` on vm-dev.
2. If CodexBar is missing, run `install-codexbar.sh` inside the existing container as `paseo`:

   ```sh
   docker exec -i --user paseo paseo sh < ~/.local/share/window-kicker/source/install-codexbar.sh
   ```

3. Verify Mac/server account equality using CLI authentication/usage metadata without printing identity. Prepare a JSON object containing only verified `claude` and `codex` email hashes. Never copy credential files or tokens.
4. Run `python3 ~/.local/share/window-kicker/source/install.py --bindings /path/to/verified-bindings.json`. This installs files and reloads user units; it does not enable timers. Existing account bindings cannot change silently.
5. Run both dry-runs, enable timers, and inspect each service result. Disable all other schedulers for these accounts after successful verification.

No provider login or container restart is required for updates. If the container home is replaced or authentication expires, restore/login through the owning CLI and re-verify account bindings.

## Offline checks

From the repository root:

```sh
python3 -m unittest discover -s tests -v
sh -n server/install-codexbar.sh
git diff --check
```

Validate installed units on Linux using `systemd-analyze --user verify` before activation. Tests never access the real provider, Docker daemon, credentials, or launchd/systemd services.
