# Window kicker context

- macOS shell utility; no build step or runtime dependencies beyond the selected provider CLI, CodexBar, and jq.
- `install.zsh [codex|claude]` defaults to Codex. Each provider has its own LaunchAgent, runtime directory, logs, and state.
- Codex runtime remains in `bin/codex-window-kicker.zsh`. Claude runtime is `bin/claude-window-kicker.zsh`.
- The installer copies the shared control script under a provider-specific filename; the filename determines its target.
- Claude's future reset timestamp means a window already runs, even if usage rounds to zero. Kick only after expiry or explicit zero usage with no reset. Never infer idle from missing/failed usage.
- Claude uses CodexBar `--source auto`: the installed OAuth-only source can report expired credentials while the CLI fallback works. Claude `--safe-mode` retains subscription authentication; `--bare` does not.
- Claude requires subscription authentication, removes API billing overrides, and uses a tool-free Haiku prompt. No real prompt is necessary for offline validation.
- Verify: `python3 -m unittest discover -s tests -v`; `zsh -n` for each shell script; `plutil -lint` on rendered LaunchAgent plists; `git diff --check`.
- Tests use temporary HOME, synthetic usage/auth data, mock provider CLIs and launchctl. Never point test mutations at the live service.
