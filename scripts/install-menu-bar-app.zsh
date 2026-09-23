#!/bin/zsh
set -euo pipefail

ROOT_DIR="${0:A:h:h}"
APP_NAME="Codex Window Kicker"
BUILD_DIR="$ROOT_DIR/.build/release"
APP_DIR="$HOME/Applications/$APP_NAME.app"
CONTENTS_DIR="$APP_DIR/Contents"

if ! xcode-select -p >/dev/null 2>&1; then
  print -u2 "Xcode Command Line Tools are required. Run: xcode-select --install"
  exit 1
fi

cd "$ROOT_DIR"
swift build -c release

mkdir -p "$CONTENTS_DIR/MacOS" "$CONTENTS_DIR/Resources"
cp "$ROOT_DIR/app/Info.plist" "$CONTENTS_DIR/Info.plist"
cp "$BUILD_DIR/CodexWindowKicker" "$CONTENTS_DIR/MacOS/CodexWindowKicker"
chmod +x "$CONTENTS_DIR/MacOS/CodexWindowKicker"

print "Installed $APP_DIR"
print "Open it from Finder or: open '$APP_DIR'"
