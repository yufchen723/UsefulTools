# Claude Monitor — macOS

Native Swift app. See the [overview](../README.md) for what it does.

## Install

Requirements: macOS 12 or newer, Xcode Command Line Tools (the installer prompts for them if missing).

1. Download or clone this folder (`ClaudeMonitor/macos`).
2. Double-click **`Install.command`** (if macOS refuses, right-click → Open). It compiles the app into `~/Applications/ClaudeUsageOrb.app`, turns on launch-at-login, and starts it. Takes about 20 seconds.
3. A sign-in window opens the first time. Sign in to claude.ai once (Google sign-in works). It closes by itself and the orb starts showing your numbers.
4. **Codex (optional).** Install Codex CLI and run `codex login`, or choose **Sign in with Codex…** from the orb menu to launch Codex’s browser sign-in. The orb reads the signed-in CLI account through `codex app-server`. Missing session/weekly windows show **N/A**. Choose *Style → Claude + Codex* to display both providers; Classic orb and Witch’s cauldron display Claude usage and task cards only.

To rebuild after editing the source, run `Install.command` again. Run `bash tests/run.sh` for parser regression checks, or add `--live` to verify the signed-in app-server connection.

## Using it

| Action | Result |
| --- | --- |
| Drag the orb | Move it anywhere; position is remembered |
| Scroll / pinch on the orb | Resize (0.6× – 2.5×) |
| Double-click the orb | Refresh now |
| Hover over a countdown pill | Shows the exact reset time |
| Menu → Sign in with Codex… | Launch Codex CLI’s browser sign-in |
| Menu → Style → Claude + Codex | Show Claude and Codex in the four-wedge orb |
| Right-click the orb, or click the menu bar drop icon | Menu |
| Click a card | Open that chat |
| **⚑ Allow** (blue card) | Open the chat to grant the permission; card stays until the chat finishes |
| **✓ Check** (green card) | Open the chat and remove the card |
| Menu → Clear finished chats | Remove all green cards at once |

## Codex desktop tasks

With *Style → Claude + Codex* selected, live local Codex desktop chats appear as blue **CODEX DESKTOP** cards, refreshed every six seconds independently of Claude sign-in. Click a card to open its Codex chat; **Check** dismisses a completed card. The monitor reads Codex’s local SQLite thread index in read-only mode and incrementally reads explicit start, completion, and interruption events from its session logs. Desktop cards exclude CLI sessions and subagents and avoid duplicate hook cards. All Codex cards must match a user-facing conversation in the local thread index; suggestion-generation jobs, internal reviews, and subagents are hidden. Previously cached background cards are removed automatically. Direct user CLI conversations remain supported. No conversation is resumed or modified.

This covers local desktop chats stored under `CODEX_HOME` (default `~/.codex`), not remote/cloud-only tasks or regular ChatGPT conversations. Approval requests are observed through Codex’s `PermissionRequest` hook and merged only into the matching desktop thread and turn. Waiting cards show **Allow**, which opens the chat for review and does not approve anything. Pending requests clear on matching `PostToolUse`, turn completion, or interruption. Since there is no approval-resolved hook, a card may stay waiting while an approved tool executes, or briefly show waiting for an automatically resolved request. A crash without a completion/interruption event can leave an observed task marked running. These local record formats are implementation details and may require updates after Codex upgrades.

## Claude Code and Codex hooks

`Install.command` also registers a hook in `~/.claude/settings.json` so terminal Claude Code sessions show up as `CLI` cards, and — when `~/.codex` exists — the same hook in `~/.codex/hooks.json` so Codex CLI sessions show up as `CODEX` cards (Codex ≥ 0.124, where hooks are stable). It only adds its own entries and leaves your existing hooks alone. To remove both:

```
python3 hooks/install-hooks.py --remove
```

## Source

- `src/main.swift` — native floating panel, Claude web session, Codex app-server usage reader, menu bar item, and chat tracker. Codex CLI handles its own credentials; the monitor does not read tokens or historical usage logs.
- `src/orb.html` — the orb itself, drawn on a `<canvas>`: liquid waves, bubbles, the HUD ring, countdown pills, and the activity cards.
- `hooks/claude-monitor-hook.py` — the Claude Code / Codex hook; writes per-session state to `~/Library/Application Support/ClaudeMonitor/code-sessions/` (Claude) or `codex-sessions/` (with `--tool codex`).
- `build.sh` — compiles with `swiftc`, assembles the `.app` bundle, ad-hoc signs it, writes a LaunchAgent for launch-at-login, and installs the hook.

Logs: `~/Library/Logs/ClaudeUsageOrb/orb.log`.

## Uninstall

Quit from the menu, run `python3 hooks/install-hooks.py --remove`, then delete `~/Applications/ClaudeUsageOrb.app`, `~/Library/LaunchAgents/com.yufan.claude-usage-orb.plist` and `~/Library/Application Support/ClaudeMonitor`.

