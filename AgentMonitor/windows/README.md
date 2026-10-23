# Agent Monitor — Windows

Electron build. See the [overview](../README.md) for what the orb shows.

**Status:** in testing. Monitors Chats, Cowork tasks, and Claude Code (cloud + terminal) — same feature set as the macOS version — but has not yet been verified on a real Windows machine.

## Requirements

- Node.js 18 or newer (https://nodejs.org) — make sure "Add to PATH" is ticked in the installer
- Internet on first run (downloads Electron once, ~100 MB)

## Start

Double-click **`start.bat`**. The first run installs Electron, then launches the orb without a console window. The orb appears at the top-right of your screen, with a drop icon in the system tray.

A sign-in window opens the first time: sign in to claude.ai once (Google sign-in works). It closes by itself and the orb starts showing your numbers.

## What it tracks

| Card tag | Source |
| --- | --- |
| *(none)* | Chats and Cowork tasks from the Claude desktop app or claude.ai |
| `CODE` | Cloud Claude Code sessions (claude.ai/code) |
| `CLI` | Claude Code running in a terminal on this computer |

Card colours: **yellow** = running (start time + live timer), **blue** = waiting for your permission (**⚑ Allow** opens the chat), **green** = finished (**✓ Check** opens the chat and dismisses the card). For `CLI` cards the buttons bring your terminal window forward instead, since there is no link to open.

A desktop notification pops up when something needs you or finishes (toggle: menu → *Desktop notifications*).

### How terminal sessions are detected

On first start the app registers a [Claude Code hook](https://docs.claude.com/en/docs/claude-code/hooks) in `%USERPROFILE%\.claude\settings.json` that runs `hooks\claude-monitor-hook.js` on session events (prompt submitted, tool use, permission prompt, stop, session end). The hook writes one small JSON file per session to `%APPDATA%\claude-monitor\code-sessions\`, which the orb reads every 6 s. It only adds its own entry and leaves your other hooks alone; hooks apply to Claude Code sessions started after installation. If your Claude Code build keeps its own status files in `%USERPROFILE%\.claude\sessions\`, those are read too.

To remove the hook, delete the entries containing `claude-monitor-hook.js` from `settings.json`.

## Using the orb

- **Drag** anywhere. **Double-click** = refresh. **Mouse wheel** over the orb = bigger / smaller (presets under right-click → Size).
- **Right-click** the orb, or click the tray icon, for the menu: refresh, hide/show, size, clear finished, sign in, notifications, launch at login, quit.

## Notes

- Log file: `%APPDATA%\claude-monitor\monitor.log`
- If the orb does not appear, run `npx electron .` in this folder from a terminal to see errors.

## Files

- `main.js` — Electron main process: orb window, tray, claude.ai session, chat / cloud / terminal tracking, notifications, hook installer
- `orb.html` + `shim.js` — the orb page (shared with the other platforms) and its mouse handling
- `hooks/claude-monitor-hook.js` — the Claude Code hook
- `start.bat` + `start-hidden.vbs` — installer + launcher
