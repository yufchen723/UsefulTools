# Claude Monitor

A small floating orb for macOS that shows your Claude plan usage at a glance — and a live card for every chat that is working for you right now.

![Claude Monitor overview](docs/overview.png)

**Top to bottom:** the two pills count down to the next usage reset (current 5-hour session on the left, weekly on the right). The sphere fills with liquid as you use your quota — left half is the session, right half is the week — and shifts from green to yellow to red as it fills. Underneath, a card appears for each chat that is **running** (yellow, with a live timer), **waiting for your permission** (blue, with an **Allow** button that jumps to the chat), or **finished** (green, with a **Check** button that opens the chat and dismisses the card).

The orb floats above every app and every desktop, including full-screen apps. Drag it anywhere, scroll or pinch to resize it, double-click to refresh.

## Features

- **Usage at a glance** — session and weekly utilization as animated liquid, with the percentage and a countdown to each reset. Same numbers as *Settings → Usage* on claude.ai, refreshed every 60 s.
- **Chat activity cards** — every chat that is running, waiting for permission, or finished-but-unchecked shows up under the orb. Checked every 6 s. Works for chats started in the Claude desktop app or on the web.
- **One-click jump** — Allow / Check buttons open the chat so you can grant the permission or review the result.
- **Always on top, everywhere** — all Spaces, full-screen apps, every monitor.
- **Freely resizable** — scroll wheel or trackpad pinch on the orb, or pick a preset from the menu.
- **Menu bar icon** — refresh, hide/show, size, sign in again, launch at login, quit.
- **Remembers everything** — position, size, and unchecked cards survive restarts.

## Install

Requirements: macOS 12 or newer, Xcode Command Line Tools (the installer prompts for them if missing).

1. Download or clone this folder.
2. Double-click **`Install.command`** (if macOS refuses, right-click → Open). It compiles the app into `~/Applications/ClaudeUsageOrb.app`, turns on launch-at-login, and starts it. Takes about 20 seconds.
3. A sign-in window opens the first time. Sign in to claude.ai once (Google sign-in works). It closes by itself and the orb starts showing your numbers.

To rebuild after editing the source, run `Install.command` again.

## Using it

| Action | Result |
| --- | --- |
| Drag the orb | Move it anywhere; position is remembered |
| Scroll / pinch on the orb | Resize (0.6× – 2.5×) |
| Double-click the orb | Refresh now |
| Hover over a countdown pill | Shows the exact reset time |
| Right-click the orb, or click the menu bar drop icon | Menu |
| Click a card | Open that chat |
| **⚑ Allow** (blue card) | Open the chat to grant the permission; card stays until the chat finishes |
| **✓ Check** (green card) | Open the chat and remove the card |
| Menu → Clear finished chats | Remove all green cards at once |

## How it works

- `src/main.swift` — the native app: a transparent, non-activating `NSPanel` that floats at `.floating` level across all Spaces, a hidden `WKWebView` that holds your claude.ai sign-in and reads usage and chat status, the menu bar item, and the chat tracker.
- `src/orb.html` — the orb itself, drawn on a `<canvas>`: liquid waves, bubbles, the HUD ring, countdown pills, and the activity cards.
- `build.sh` — compiles with `swiftc`, assembles the `.app` bundle, ad-hoc signs it, and writes a LaunchAgent for launch-at-login.

Usage comes from the same endpoint the claude.ai settings page uses; chat activity from each conversation's `live_status`. Both are unofficial and may change — if the orb shows **Offline**, that is the first thing to check. The app talks only to claude.ai and stores your sign-in in its own WebKit data store.

Logs: `~/Library/Logs/ClaudeUsageOrb/orb.log`.

## Uninstall

Quit from the menu, then delete `~/Applications/ClaudeUsageOrb.app` and `~/Library/LaunchAgents/com.yufan.claude-usage-orb.plist`.

## License

MIT
