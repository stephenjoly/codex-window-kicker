#!/bin/sh
# Run inside the existing Paseo container as paseo; no container rebuild/restart.
set -eu
umask 077
version=0.77.0
digest=e1eb0d0756857b4b8940e1ef075627fc9582d7b55de067a6208dc1084b66b437
test "$(uname -m)" = x86_64 || { echo 'Pinned release requires x86_64' >&2; exit 1; }
target="$HOME/.local/share/window-kicker/vendor/codexbar/v$version"
mkdir -p "$target"
curl -fLsS --connect-timeout 15 --max-time 180 \
  "https://github.com/steipete/CodexBar/releases/download/v$version/CodexBarCLI-v$version-linux-musl-x86_64.tar.gz" \
  -o "$target/release.tar.gz"
printf '%s  %s\n' "$digest" "$target/release.tar.gz" | sha256sum -c -
tar -xzf "$target/release.tar.gz" -C "$target"
"$target/CodexBarCLI" --version
