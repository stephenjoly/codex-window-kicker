# Codex Window Kicker

Codex Window Kicker is a five-hour window kicker for macOS. A small native
menu-bar app shows the worker's state and controls the existing LaunchAgent;
the worker continues running in the background whether or not the app is open.

Every five minutes, the worker asks CodexBar for the primary five-hour usage
window. When it observes a newly reset, unused window and it remains unused for
ten minutes, the worker sends one minimal `pong` prompt to start that window.
It does not independently manage any other usage window.

![Terminal demo](assets/terminal-demo.svg)

## Requirements

- macOS 15 or later
- Xcode command-line tools for the menu-bar app (`xcode-select --install`)
- [Codex CLI](https://github.com/openai/codex)
- [CodexBar CLI](https://github.com/steipete/CodexBar), which reports usage
- [jq](https://jqlang.github.io/jq/)

Homebrew can install the command-line dependencies. The worker installer offers
to install missing dependencies when Homebrew is available.

## Install the worker

```sh
git clone https://github.com/stephenjoly/codex-window-kicker.git
cd codex-window-kicker
./install.zsh
```

The installer copies the worker and control command to:

```text
~/Library/Application Support/CodexWindowKicker/
```

It installs this LaunchAgent:

```text
~/Library/LaunchAgents/com.codex-window-kicker.agent.plist
```

The runtime copy intentionally lives outside `Documents`, where macOS privacy
controls can prevent launchd from executing scripts. The installer captures the
current shell `PATH` for launchd. Re-run `./install.zsh` after installing a new
dependency or updating the worker.

## Build and install the menu-bar app

Build the local, unsigned app after the worker is installed:

```sh
./scripts/install-menu-bar-app.zsh
```

The script runs a release Swift build and assembles
`~/Applications/Codex Window Kicker.app`. Open it from Finder or run:

```sh
open "$HOME/Applications/Codex Window Kicker.app"
```

macOS may ask you to confirm opening this unsigned local app the first time;
use Finder's **Open** command when prompted.

The app is an agent application, so it has a menu-bar icon and no Dock icon.
Its compact menu shows Enabled, the latest poll, primary five-hour usage and
reset when available, the last kickoff, and the latest error. It refreshes from
the worker's status file and does not query CodexBar itself.

## Kickoff Prompt

The automatic kickoff uses a minimal Codex command:

```sh
codex exec \
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
```

## Use it

Choose the menu-bar icon to open the controls:

- **Enabled** loads and kickstarts the installed LaunchAgent. Turning it off
  unloads the agent and keeps status, logs, and qualification state.
- **View Logs** opens the normal worker log.
- **Run Dry Check** runs an observational worker check. It never sends a Codex
  prompt and does not change the scheduled worker's qualification state.
- **Settings** shows the runtime paths and refresh information.

Icon state conveys current operation: the active icon means enabled and healthy,
the paused icon means disabled, and the warning icon means a worker,
dependency, malformed-status, stale-status, or control error needs attention.

The menu-bar app never sends a Codex prompt. The shell worker is the sole
component allowed to run the minimal kickoff command.

## Command-line controls

```sh
"$HOME/Library/Application Support/CodexWindowKicker/codex-window-kicker-control.zsh" status
```

Keep the installation and its state, but stop or resume automatic kickoff prompts:

```sh
CONTROL="$HOME/Library/Application Support/CodexWindowKicker/codex-window-kicker-control.zsh"

"$CONTROL" off    # stop the LaunchAgent
"$CONTROL" on     # load and start it again
"$CONTROL" status # check whether it is enabled
```

Run `./install.zsh` once after updating to install the control command.

## Dry check

Run an observational worker check without sending the kickoff prompt:

```sh
DRY_RUN=1 "$HOME/Library/Application Support/CodexWindowKicker/codex-window-kicker.zsh"
```

Inspect its machine-readable state or follow the logs:

```sh
cat "$HOME/Library/Application Support/CodexWindowKicker/state/status.json"
tail -f "$HOME/Library/Application Support/CodexWindowKicker/codex-window-kicker.log"
```

`state/status.json` is written atomically after each poll. It contains a schema
version, enabled state, polling timestamp, primary five-hour usage percentage,
reset time, last kickoff time, and latest error. See
[the architecture note](docs/ARCHITECTURE.md) for the contract and component
boundaries.

## Troubleshooting

If the app shows a warning, open **View Logs** and inspect `lastError` in the
status file. Common repairs are:

- Install or authenticate Codex, CodexBar, and jq, then rerun `./install.zsh`
  so the LaunchAgent receives the current `PATH`.
- Use **Enabled** or `"$CONTROL" on` to load and kickstart the agent after it
  has been disabled.
- Use `"$CONTROL" status` to inspect whether launchd currently has the agent
  loaded.
- Run a dry check to refresh reported usage without sending a prompt.

## Build and test

Run the shell tests:

```sh
zsh tests/shell/test-status-and-control.zsh
```

Run the native app tests and a release build:

```sh
swift test
swift build -c release
./scripts/install-menu-bar-app.zsh
```

## Uninstall

```sh
./uninstall.zsh
```

Uninstall unloads the LaunchAgent and removes its plist. It retains the runtime
directory, including logs and state, for inspection or later reuse. Remove that
directory only when you have decided it is no longer needed:

```sh
rm -rf "$HOME/Library/Application Support/CodexWindowKicker"
```

Remove `~/Applications/Codex Window Kicker.app` separately if you no longer
want the local menu-bar app.
