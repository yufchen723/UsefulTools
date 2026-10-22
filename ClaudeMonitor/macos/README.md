# Claude Monitor — macOS

Native Swift app. See the [overview](../README.md) for what it does.

## Install

Requirements: macOS 12 or newer, Xcode Command Line Tools (the installer prompts for them if missing).

1. Download or clone this folder (`ClaudeMonitor/macos`).
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

## Claude Code hooks

`Install.command` also registers a hook in `~/.claude/settings.json` so terminal Claude Code sessions show up as `CLI` cards. It only adds its own entry and leaves your existing hooks alone. To remove it:

```
python3 hooks/install-hooks.py --remove
```

## Source

- `src/main.swift` — the native app: a transparent, non-activating `NSPanel` that floats at `.floating` level across all Spaces, a hidden `WKWebView` that holds your claude.ai sign-in and reads usage and chat status, the menu bar item, and the chat tracker.
- `src/orb.html` — the orb itself, drawn on a `<canvas>`: liquid waves, bubbles, the HUD ring, countdown pills, and the activity cards.
- `hooks/claude-monitor-hook.py` — the Claude Code hook; writes per-session state to `~/Library/Application Support/ClaudeMonitor/code-sessions/`.
- `build.sh` — compiles with `swiftc`, assembles the `.app` bundle, ad-hoc signs it, writes a LaunchAgent for launch-at-login, and installs the hook.

Logs: `~/Library/Logs/ClaudeUsageOrb/orb.log`.

## Uninstall

Quit from the menu, run `python3 hooks/install-hooks.py --remove`, then delete `~/Applications/ClaudeUsageOrb.app`, `~/Library/LaunchAgents/com.yufan.claude-usage-orb.plist` and `~/Library/Application Support/ClaudeMonitor`.

