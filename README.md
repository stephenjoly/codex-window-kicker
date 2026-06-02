# Codex Window Kicker

Starts a fresh Codex usage window automatically after a reset if the window is still unused.

The LaunchAgent runs every 5 minutes. The script checks Codex usage through CodexBar:

```sh
codexbar usage --provider codex --source oauth --format json --json-only
```

When the primary 5-hour window is fresh, `usedPercent` is `0`, and that state has remained true for 10 minutes, it runs one tiny Codex prompt:

```sh
codex exec -C /Users/stephenjoly/Scratchpad --skip-git-repo-check -s read-only -a never "Reply exactly: pong"
```

## Install

Install the runnable copy outside `Documents` so launchd is not blocked by macOS privacy controls:

```sh
mkdir -p "$HOME/Library/Application Support/CodexWindowKicker" "$HOME/Library/LaunchAgents"
cp codex-window-kicker.zsh "$HOME/Library/Application Support/CodexWindowKicker/"
chmod +x "$HOME/Library/Application Support/CodexWindowKicker/codex-window-kicker.zsh"
cp com.stephenjoly.codex-window-kicker.plist "$HOME/Library/LaunchAgents/"
launchctl bootstrap gui/$(id -u) "$HOME/Library/LaunchAgents/com.stephenjoly.codex-window-kicker.plist"
launchctl kickstart -k gui/$(id -u)/com.stephenjoly.codex-window-kicker
```

Reload after changes:

```sh
cp com.stephenjoly.codex-window-kicker.plist ~/Library/LaunchAgents/
cp codex-window-kicker.zsh "$HOME/Library/Application Support/CodexWindowKicker/"
launchctl bootout gui/$(id -u) ~/Library/LaunchAgents/com.stephenjoly.codex-window-kicker.plist
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.stephenjoly.codex-window-kicker.plist
launchctl kickstart -k gui/$(id -u)/com.stephenjoly.codex-window-kicker
```

## Logs

```sh
tail -f "$HOME/Library/Application Support/CodexWindowKicker/codex-window-kicker.log"
```

## Disable

```sh
launchctl bootout gui/$(id -u) ~/Library/LaunchAgents/com.stephenjoly.codex-window-kicker.plist
```
