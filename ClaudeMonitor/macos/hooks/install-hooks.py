#!/usr/bin/env python3
"""Registers (or removes, with --remove) the Claude Monitor hook in ~/.claude/settings.json.

Idempotent: existing user hooks are left alone; ours is identified by its command path.
"""
import json, os, sys

SETTINGS = os.path.join(os.path.expanduser("~"), ".claude", "settings.json")
HOOK = os.path.join(os.path.expanduser("~"), "Library", "Application Support", "ClaudeMonitor", "claude-monitor-hook.py")
EVENTS = ["UserPromptSubmit", "PreToolUse", "PostToolUse", "Notification", "Stop", "SubagentStop", "SessionEnd"]
CMD = f'/usr/bin/env python3 "{HOOK}"'


def load():
    try:
        with open(SETTINGS) as f:
            return json.load(f)
    except FileNotFoundError:
        return {}
    except Exception as e:
        print(f"Could not parse {SETTINGS}: {e}. Hooks not installed; fix the file and run again.")
        sys.exit(1)


def is_ours(h):
    return any("claude-monitor-hook.py" in (x.get("command") or "") for x in h.get("hooks", []))


def main():
    remove = "--remove" in sys.argv
    s = load()
    hooks = s.setdefault("hooks", {})
    for ev in EVENTS:
        lst = [h for h in hooks.get(ev, []) if not is_ours(h)]
        if not remove:
            lst.append({"hooks": [{"type": "command", "command": CMD, "timeout": 5}]})
        if lst:
            hooks[ev] = lst
        else:
            hooks.pop(ev, None)
    if not hooks:
        s.pop("hooks", None)
    os.makedirs(os.path.dirname(SETTINGS), exist_ok=True)
    with open(SETTINGS, "w") as f:
        json.dump(s, f, indent=2)
        f.write("\n")
    print("Claude Code hooks " + ("removed." if remove else "installed (take effect in new Claude Code sessions)."))


if __name__ == "__main__":
    main()
