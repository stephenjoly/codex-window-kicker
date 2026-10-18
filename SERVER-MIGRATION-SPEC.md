# Server window kicker migration

## Goal

Make vm-dev the sole scheduler for Claude and Codex usage-window kickoff prompts, so the MacBook can sleep or be offline.

Approved by Stephen on 2026-10-18. Implemented using the existing Paseo container's matching provider accounts; the MacBook jobs are disabled after server verification.

## Behavior and interface

- Install one background systemd user timer per provider on vm-dev as stephen. Check every five minutes, including after reboot without an interactive login; linger is already enabled.
- Reuse existing Claude/Codex subscription logins inside the running Paseo container. Invoke provider commands as the paseo user with the existing persistent home. Do not copy credentials, add API billing, rebuild the container, or restart Paseo.
- Install a pinned official Linux CodexBar CLI release in persistent application storage, verifying its published digest when available. Use it for usage reads, with explicit provider/source selection. No GUI or new container.
- Add a Linux-compatible runner using existing Python 3. Preserve the tiny prompt, ten-minute idle delay, independent state, weekly-limit checks, timeouts, failure cooldown, and duplicate protection. Use provider-reported reset boundaries; never treat unreadable usage as idle.
- Keep prompts isolated from tools, hooks, user rules, MCP servers, and persisted sessions using flags supported by each installed CLI.
- Confirm the server logins correspond to the intended MacBook accounts without printing account identity or credentials. If they differ, stop migration before disabling local jobs and report the decision needed.
- Store runner/config under conventional hidden application directories; expose systemctl on/off/status and journalctl logs. Do not add visible files to the server home directory.
- Once server usage checks, timer activation, and service execution succeed for both providers, disable both MacBook LaunchAgents while preserving their files/state for rollback.

## Acceptance checks

1. Offline fixtures cover both providers' reset eligibility, active/rounded-zero windows, debounce, duplicate suppression, invalid/failed usage, weekly exhaustion, successful/failed prompts, and timeouts.
2. systemd unit validation passes; a real read-only usage check succeeds for each server account. Dry-run confirms decisions without spending a prompt.
3. Both server timers are enabled and scheduled, and their first executions complete without configuration/authentication errors. Do not force a paid kickoff while windows are active.
4. Both MacBook jobs are unloaded only after server verification. Report any provider that cannot be migrated; retain its local job until healthy.
5. Update project operational docs and canonical homelab wiki with placement, commands, and rollback. Commit/push scoped changes.

## Rollback

Disable the server timers before re-enabling the existing MacBook control commands. Keep installed state and logs on both machines. No credential or container changes to undo.

## Out of scope

Other providers, graphical UI, moving Paseo, changing provider accounts or limits, container rebuilds, and unrelated MacBook Codex repairs after its scheduler is retired.
