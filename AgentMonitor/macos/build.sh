#!/bin/bash
# Builds Claude Usage Orb into ~/Applications, turns on launch-at-login, and starts it.
set -euo pipefail
cd "$(dirname "$0")"
LOG="$PWD/build.log"
exec > >(tee "$LOG") 2>&1

APP="$HOME/Applications/ClaudeUsageOrb.app"
LABEL="com.yufan.claude-usage-orb"
AGENT="$HOME/Library/LaunchAgents/$LABEL.plist"

if ! xcrun --find swiftc >/dev/null 2>&1; then
  echo "Xcode Command Line Tools are needed. Click 'Install' in the dialog, then run this script again."
  xcode-select --install || true
  exit 1
fi

mkdir -p build
echo "Compiling…"
xcrun swiftc -O -swift-version 5 -o build/ClaudeUsageOrb src/main.swift -framework Cocoa -framework WebKit

pkill -x ClaudeUsageOrb 2>/dev/null || true
sleep 0.5
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp build/ClaudeUsageOrb "$APP/Contents/MacOS/"
cp src/orb.html "$APP/Contents/Resources/"
cp src/Info.plist "$APP/Contents/"
codesign --force --deep -s - "$APP"

mkdir -p "$HOME/Library/LaunchAgents"
cat > "$AGENT" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key><array><string>/usr/bin/open</string><string>-a</string><string>$APP</string></array>
  <key>RunAtLoad</key><true/>
</dict></plist>
EOF

# Terminal sessions: install the hook script + register it for Claude Code (~/.claude/settings.json)
# and, if Codex CLI is installed, for Codex too (~/.codex/hooks.json).
SUPPORT="$HOME/Library/Application Support/ClaudeMonitor"
mkdir -p "$SUPPORT/code-sessions" "$SUPPORT/codex-sessions"
cp hooks/claude-monitor-hook.py "$SUPPORT/claude-monitor-hook.py"
chmod +x "$SUPPORT/claude-monitor-hook.py"
python3 hooks/install-hooks.py || echo "(hooks not installed — terminal sessions won't show; everything else works)"

open "$APP"
echo "BUILD_OK — Claude Usage Orb is running."
