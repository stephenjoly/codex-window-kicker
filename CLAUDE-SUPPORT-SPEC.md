# Claude window kicker

## Goal

Run the existing automatic usage-window kickoff for Claude Code alongside Codex on this Mac. Keep each provider independently controllable.

Approved by Stephen on 2026-10-18: a quiet background job that sends one small prompt whenever Claude's five-hour window resets.

## Behavior and interface

- Preserve existing Codex installation, command paths, schedule, and state.
- Add an explicit Claude install option, a separate LaunchAgent, and separate runtime logs, lock, debounce, and last-success state.
- Poll Claude usage through the installed CodexBar CLI every five minutes. The verified automatic-source response includes a 300-minute primary window. A future reset means the window already runs, including when usage rounds to zero. Expired windows (or explicit zero with no reset) are eligible; missing usage is not.
- Wait ten minutes after observing an eligible unused window before sending one minimal Claude `pong` request. Cancel pending kickoff when usage resumes. Suppress repeated successful kicks for the same usage window.
- Use the installed Claude Code subscription login, a low-cost model, no tools or MCP servers, no session persistence, and disabled user customizations. Verify supported flags against the installed CLI. Do not use API-key billing for the kickoff.
- Missing dependencies, unavailable usage, invalid data, and authentication failures must skip safely and log a concise reason without credential material.
- Provide Claude `on`, `off`, and `status` controls. Disabling preserves installation and state; uninstall remains separate.
- Update README with install, status, dry-run, disable, and uninstall commands for both providers.
- No graphical screens; terminal commands and logs are the interface.

## Acceptance checks

1. Shell syntax checks and rendered LaunchAgent plist validation pass.
2. Synthetic CLI fixtures cover Claude eligibility, ten-minute waiting, resumed usage, malformed/failed usage reads, kickoff success/failure, and duplicate suppression.
3. Mocked launchctl verifies Claude install/control/uninstall target only its own service and files. Existing Codex behavior remains compatible.
4. Dry-run demonstrates eligible Claude detection without sending a prompt.
5. Install Claude support locally, verify its LaunchAgent is loaded, and inspect its first scheduled result. Report whether an actual kickoff occurred; do not force one merely to test.

## Out of scope

- Menu bar UI, other providers, authentication setup, dependency upgrades, or changing subscription limits.
- Altering unrelated branches or worktrees.

## Implementation approach

Keep this a small shell utility. Reuse existing runtime/lifecycle patterns where practical, with explicit provider selection and isolated provider state. Add only the fixtures needed to verify changed behavior. No new runtime dependencies.
