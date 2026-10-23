#!/usr/bin/env python3
"""Registers (or removes, with --remove) the Claude Monitor hook for

  * Claude Code — in ~/.claude/settings.json
  * Codex CLI   — in ~/.codex/hooks.json (only if ~/.codex exists, i.e. Codex is installed)

Idempotent: existing user hooks are left alone; ours is identified by its command path.
Codex uses the same hooks.json shape as Claude Code (events → matcher groups → hooks).
"""
import json, os, sys

HOME = os.path.expanduser("~")
HOOK = os.path.join(HOME, "Library", "Application Support", "ClaudeMonitor", "claude-monitor-hook.py")

TARGETS = [
    {
        "name": "Claude Code",
        "file": os.path.join(HOME, ".claude", "settings.json"),
        "events": ["UserPromptSubmit", "PreToolUse", "PostToolUse", "Notification", "Stop", "SubagentStop", "SessionEnd"],
        "cmd": f'/usr/bin/env python3 "{HOOK}"',
        "required": True,
    },
    {
        "name": "Codex CLI",
        "file": os.path.join(os.environ.get("CODEX_HOME") or os.path.join(HOME, ".codex"), "hooks.json"),
        "events": ["UserPromptSubmit", "PreToolUse", "PostToolUse", "PermissionRequest", "Stop", "SubagentStop", "Interrupt", "SessionEnd"],
        "cmd": f'/usr/bin/env python3 "{HOOK}" --tool codex',
        "required": False,   # skipped when Codex isn't installed
    },
]


def load(path):
    try:
        with open(path) as f:
            return json.load(f)
    except FileNotFoundError:
        return {}
    except Exception as e:
        print(f"Could not parse {path}: {e}. Hooks not installed there; fix the file and run again.")
        return None


def is_ours(h):
    return any("claude-monitor-hook.py" in (x.get("command") or "") for x in h.get("hooks", []))


def install(target, remove):
    folder = os.path.dirname(target["file"])
    if not target["required"] and not os.path.isdir(folder):
        return f"{target['name']}: not installed (no {folder}), skipped."
    s = load(target["file"])
    if s is None:
        return None
    hooks = s.setdefault("hooks", {})
    for ev in target["events"]:
        lst = [h for h in hooks.get(ev, []) if not is_ours(h)]
        if not remove:
            lst.append({"hooks": [{"type": "command", "command": target["cmd"], "timeout": 5}]})
        if lst:
            hooks[ev] = lst
        else:
            hooks.pop(ev, None)
    if not hooks:
        s.pop("hooks", None)
    os.makedirs(folder, exist_ok=True)
    with open(target["file"], "w") as f:
        json.dump(s, f, indent=2)
        f.write("\n")
    return f"{target['name']} hooks " + ("removed." if remove else "installed (take effect in new sessions).")


def main():
    remove = "--remove" in sys.argv
    failed = False
    for t in TARGETS:
        msg = install(t, remove)
        if msg is None:
            failed = True
        else:
            print(msg)
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
