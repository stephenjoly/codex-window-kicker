#!/usr/bin/env python3
"""Install user units/configs on vm-dev. Does not enable timers or send prompts."""
import argparse
import json
import os
from pathlib import Path
import shutil
import subprocess


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--bindings", type=Path, required=True,
                        help="Verified SHA-256 account-email bindings; no credentials")
    args = parser.parse_args()
    bindings = json.loads(args.bindings.read_text())
    if set(bindings) != {"codex", "claude"} or any(
            not isinstance(value, str) or len(value) != 64 or any(c not in "0123456789abcdef" for c in value)
            for value in bindings.values()):
        parser.error("expected verified Claude and Codex account fingerprints")
    os.umask(0o077)
    source = Path(__file__).resolve().parent
    runtime = Path.home() / ".local/share/window-kicker"
    config_dir = Path.home() / ".config/window-kicker"
    units = Path.home() / ".config/systemd/user"
    for directory in (runtime, config_dir, units):
        directory.mkdir(parents=True, exist_ok=True)
    shutil.copy2(source / "window_kicker.py", runtime / "window_kicker.py")
    for name in ("window-kicker@.service", "window-kicker@.timer"):
        shutil.copy2(source / name, units / name)
    for provider in ("codex", "claude"):
        config = {"provider": provider, "container": "paseo", "expected_account": bindings[provider],
                  "codexbar": "/home/paseo/.local/share/window-kicker/vendor/codexbar/v0.77.0/CodexBarCLI",
                  "state_dir": str(Path.home() / ".local/state/window-kicker" / provider),
                  "command_timeout": 120}
        path = config_dir / (provider + ".json")
        # Reinstallation must not silently rebind an existing scheduler to another account.
        if path.exists() and json.loads(path.read_text()).get("expected_account") != bindings[provider]:
            raise SystemExit("Existing account binding differs; inspect before reinstalling")
        path.write_text(json.dumps(config, indent=2) + "\n")
    subprocess.run(["systemctl", "--user", "daemon-reload"], check=True)
    print("Installed. Verify dry-runs before enabling window-kicker@{claude,codex}.timer.")


if __name__ == "__main__":
    main()
