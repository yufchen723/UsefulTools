#!/usr/bin/env python3
"""Claude Code hook for Claude Monitor.

Claude Code runs this on session events (UserPromptSubmit, PreToolUse, PostToolUse,
Notification, Stop, SessionEnd) and pipes the event as JSON on stdin. We keep one small
JSON file per session so the floating orb can show terminal sessions as cards.
Never prints anything and never fails loudly, so it can't interfere with Claude Code.
"""
import json, os, sys, time

STATE_DIR = os.path.join(os.path.expanduser("~"), "Library", "Application Support", "ClaudeMonitor", "code-sessions")
DONE_LIKE = {"done"}


def main():
    try:
        ev = json.load(sys.stdin)
    except Exception:
        return
    sid = ev.get("session_id")
    if not sid:
        return
    name = ev.get("hook_event_name", "")
    os.makedirs(STATE_DIR, exist_ok=True)
    path = os.path.join(STATE_DIR, f"{sid}.json")
    now = int(time.time() * 1000)

    cur = {}
    try:
        with open(path) as f:
            cur = json.load(f)
    except Exception:
        pass

    cwd = ev.get("cwd") or cur.get("cwd") or ""
    folder = os.path.basename(cwd.rstrip("/")) or cwd
    cur.setdefault("id", sid)
    cur.setdefault("kind", "code-local")
    cur["cwd"] = cwd
    cur["pid"] = os.getppid()          # the claude process; lets the orb drop sessions whose process is gone
    cur["updatedAt"] = now

    if name == "UserPromptSubmit":
        prompt = " ".join((ev.get("prompt") or "").split())
        if prompt:
            cur["prompt"] = prompt[:80]
        cur["title"] = folder + (" · " + cur["prompt"][:48] if cur.get("prompt") else "")
        if cur.get("state") != "running" and cur.get("state") != "permission":
            cur["startedAt"] = now
            cur["endedAt"] = None
        cur["state"] = "running"
    elif name in ("PreToolUse", "PostToolUse", "SubagentStop", "PreCompact"):
        if cur.get("state") != "running":
            cur.setdefault("startedAt", now)
            cur["state"] = "running"
            cur["endedAt"] = None
        cur.setdefault("title", folder)
    elif name == "Notification":
        msg = (ev.get("message") or "") + " " + (ev.get("notification_type") or "") + " " + (ev.get("title") or "")
        low = msg.lower()
        cur.setdefault("title", folder)
        cur.setdefault("startedAt", now)
        if "permission" in low or "approve" in low or "allow" in low:
            cur["state"] = "permission"
        elif "idle" in low or "waiting for your input" in low:
            cur["state"] = "done"
            cur["endedAt"] = now
    elif name == "Stop":
        if ev.get("stop_hook_active"):
            return
        cur.setdefault("title", folder)
        cur.setdefault("startedAt", now)
        cur["state"] = "done"
        cur["endedAt"] = now
    elif name == "SessionEnd":
        # Keep a finished-but-unchecked card; drop anything else.
        if cur.get("state") != "done":
            try:
                os.remove(path)
            except Exception:
                pass
            return
        cur["pid"] = None
    elif name == "SessionStart":
        cur.setdefault("title", folder)
        if "state" not in cur:
            return  # nothing to show until the user actually sends a prompt
    else:
        return

    tmp = path + ".tmp"
    try:
        with open(tmp, "w") as f:
            json.dump(cur, f)
        os.replace(tmp, path)
    except Exception:
        pass


if __name__ == "__main__":
    try:
        main()
    except Exception:
        pass
