# Claude Monitor — Linux

Electron build. See the [overview](../README.md) for what the orb shows.

**Status:** stable, in daily use for **Claude Code terminal sessions**. Usage percentages and chat/Cowork cards need a claude.ai sign-in, which is present in the code but not yet verified on Linux — treat them as experimental.

## Requirements

- Node.js 18 or newer (https://nodejs.org)
- Internet on first run (downloads Electron once, ~100 MB)
- Optional, for click-to-focus on terminal windows: `gcc` and `libx11-dev` (X11 only)

## Start

```
chmod +x start.sh    # first time only
./start.sh
```

The first run installs Electron and builds the small `tools/wintool` helper if `gcc` is available. The orb appears at the top-right of your screen, with a drop icon in the system tray.

## Claude Code sessions

Every Claude Code session running under your user on this computer shows up as a card tagged **CLI**:

| Colour | Meaning |
| --- | --- |
| Yellow | Working — start time and live elapsed timer |
| Blue | Waiting for you — the card says what for (e.g. a permission prompt); answer it in that terminal |
| Green | Finished its turn, or *Closed* if the session exited while working |

- Click a card, or its **⚑ Terminal** / **✓ Check** button, to bring that session's terminal window to the front (switches workspace if needed). **✓ Check** also dismisses the card. Works for normal terminal windows on X11; it can't pick a tab inside tmux, SSH or an IDE terminal.
- A desktop notification pops up when a session needs you or finishes. Toggle it in the menu: *Desktop notifications (Claude Code)*.
- Right-click → *Claude Code on this computer* lists every live session, including idle ones; click one to focus its terminal.

How it works: it reads the status files Claude Code keeps in `~/.claude/sessions/` every 2 s. Read-only — it doesn't change Claude Code's settings, add hooks, or send anything anywhere. Only your own user's sessions are visible.

## Using the orb

- **Drag** anywhere. **Double-click** = refresh. **Mouse wheel** over the orb = bigger / smaller (presets under right-click → Size).
- **Right-click** the orb, or click the tray icon, for the menu: refresh, hide/show, size, sign in, launch at login, quit.

## Notes

- Log file: `~/.config/claude-monitor/monitor.log`
- On Wayland, transparency and always-on-top depend on your compositor. If the orb shows a black box, start it from an X11 session or run `./node_modules/.bin/electron . --ozone-platform=x11`.
- Some X11 setups (e.g. XFCE over xrdp) are slow to show transparent windows; the orb forces itself visible after a few seconds.

## Files

- `main.js` — Electron main process: orb window, tray, claude.ai session, Claude Code session polling, notifications
- `orb.html` + `shim.js` — the orb page (shared with the other platforms) and its mouse handling
- `tools/wintool.c` — tiny X11 helper: list windows / activate one
- `start.sh` — installer + launcher
