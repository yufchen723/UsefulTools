#!/bin/bash
# Claude Monitor — Linux launcher. First run installs Electron (needs Node.js 18+ and internet).
cd "$(dirname "$0")"
if ! command -v node >/dev/null 2>&1; then
  echo "Node.js is required. Install it from https://nodejs.org (or: sudo apt install nodejs npm), then run this again."
  exit 1
fi
if [ ! -d node_modules/electron ]; then
  echo "Installing Electron (one-time, ~100 MB)…"
  npm install --no-audit --no-fund || exit 1
fi
# Small X11 helper used to bring a Claude Code session's terminal to the front.
if [ ! -x tools/wintool ] && command -v gcc >/dev/null 2>&1; then
  gcc -O2 -o tools/wintool tools/wintool.c -lX11 || echo "Note: couldn't build tools/wintool (needs libx11-dev); clicking CLI cards won't raise terminals."
fi
mkdir -p "$HOME/.local/share/claude-monitor"
nohup ./node_modules/.bin/electron . >"$HOME/.local/share/claude-monitor/stdout.log" 2>&1 &
echo "Claude Monitor started. Look for the orb at the top-right of your screen and the drop icon in the system tray."
