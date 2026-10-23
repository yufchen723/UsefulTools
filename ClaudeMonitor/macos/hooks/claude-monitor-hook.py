#!/usr/bin/env python3
"""Claude Code / Codex CLI hook for Claude Monitor.

Both tools run this on session events and pipe the event as JSON on stdin. The event
names and fields are the same for both (session_id, cwd, prompt, hook_event_name):

  Claude Code: UserPromptSubmit, PreToolUse, PostToolUse, Notification, Stop, SubagentStop, SessionEnd
  Codex CLI:   UserPromptSubmit, PreToolUse, PostToolUse, PermissionRequest, Stop, SubagentStop, Interrupt, SessionEnd

We keep one small JSON file per session so the floating orb can show terminal sessions as
cards. `--tool codex` writes to codex-sessions/ with kind "codex-local"; the default is
Claude Code (code-sessions/, kind "code-local").
Never prints anything and never fails loudly, so it can't interfere with either tool.
"""
import json, os, sys, time, hashlib, fcntl, re

SUPPORT = os.path.join(os.path.expanduser("~"), "Library", "Application Support", "ClaudeMonitor")
TOOLS = {
    "claude": {"dir": "code-sessions", "kind": "code-local"},
    "codex": {"dir": "codex-sessions", "kind": "codex-local"},
}


def tool_from_argv():
    if "--tool" in sys.argv:
        i = sys.argv.index("--tool")
        if i + 1 < len(sys.argv) and sys.argv[i + 1] in TOOLS:
            return sys.argv[i + 1]
    return "claude"


def codex_event(ev, state_dir):
    """Record observations only. Never return an approval decision to Codex."""
    sid = ev.get("session_id", "")
    if not re.fullmatch(r"[A-Za-z0-9_-]+", sid):
        return
    name = ev.get("hook_event_name", "")
    if name not in {"UserPromptSubmit", "PreToolUse", "PostToolUse", "PermissionRequest",
                    "Stop", "Interrupt", "SessionEnd", "SubagentStop"}:
        return
    os.makedirs(state_dir, exist_ok=True)
    path = os.path.join(state_dir, sid + ".json")
    # Parallel tool hooks share this session. Serialize the read/modify/write operation.
    with open(path + ".lock", "a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        try:
            with open(path) as source:
                cur = json.load(source)
        except (OSError, ValueError):
            cur = {}
        now = int(time.time() * 1000)
        turn = ev.get("turn_id")
        if turn and turn != cur.get("turnId"):
            # Ignore a delayed tool callback from an already observed older turn.
            if turn in cur.get("previousTurns", []):
                return
            previous = cur.get("previousTurns", [])
            if cur.get("turnId"):
                previous = (previous + [cur["turnId"]])[-32:]
            cur.update(turnId=turn, previousTurns=previous, pendingApprovals={}, startedAt=now, endedAt=None, state="running")
        if cur.get("approvalSchema") != 2:
            cur["pendingApprovals"] = {}
            cur["approvalSchema"] = 2
        pending = cur.setdefault("pendingApprovals", {})
        tool_input = ev.get("tool_input")
        # Approval input may add a human-readable description absent from PostToolUse.
        if ev.get("tool_name") in {"Bash", "apply_patch", "Edit", "Write"} and isinstance(tool_input, dict):
            tool_input = {"command": tool_input.get("command")}
        signature = hashlib.sha256(json.dumps([ev.get("tool_name"), tool_input],
                                              sort_keys=True, ensure_ascii=False).encode()).hexdigest()
        if name == "PermissionRequest":
            pending[signature] = pending.get(signature, 0) + 1
        elif name == "PostToolUse":
            if pending.get(signature, 0) > 1:
                pending[signature] -= 1
            else:
                pending.pop(signature, None)
        elif name in {"Stop", "Interrupt", "SessionEnd"}:
            if ev.get("stop_hook_active"):
                return
            pending.clear()
            cur.update(state="done", endedAt=now)
        elif name == "UserPromptSubmit":
            pending.clear()
            cur.update(state="running", startedAt=now, endedAt=None)
        # Late callbacks must not resurrect a completed turn.
        if cur.get("state") != "done":
            cur["state"] = "permission" if pending else "running"
        cur.setdefault("startedAt", now)
        cwd = ev.get("cwd") or cur.get("cwd") or ""
        cur.update(id=sid, kind="codex-local", cwd=cwd, updatedAt=now,
                   pid=None if name == "SessionEnd" else os.getppid(), lastEvent=name)
        prompt = " ".join((ev.get("prompt") or "").split())
        if prompt:
            cur["prompt"] = prompt[:80]
        cur["title"] = (os.path.basename(cwd.rstrip("/")) or "Codex") + (" · " + cur["prompt"][:48] if cur.get("prompt") else "")
        tmp = path + ".tmp"
        with open(tmp, "w") as output:
            json.dump(cur, output)
        os.replace(tmp, path)


def main():
    try:
        ev = json.load(sys.stdin)
    except Exception:
        return
    sid = ev.get("session_id")
    if not sid:
        return
    selected = tool_from_argv()
    if selected == "codex":
        try:
            codex_event(ev, os.path.join(SUPPORT, TOOLS["codex"]["dir"]))
        except Exception:
            pass  # Observation failure must never affect the approval decision.
        return
    tool = TOOLS[selected]
    state_dir = os.path.join(SUPPORT, tool["dir"])
    name = ev.get("hook_event_name", "")
    os.makedirs(state_dir, exist_ok=True)
    path = os.path.join(state_dir, f"{sid}.json")
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
    cur["kind"] = tool["kind"]
    cur["cwd"] = cwd
    cur["pid"] = os.getppid()          # the claude/codex process; lets the orb drop sessions whose process is gone
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
    elif name in ("PreToolUse", "PostToolUse", "SubagentStop", "PreCompact", "PostCompact", "SubagentStart"):
        if cur.get("state") != "running":
            cur.setdefault("startedAt", now)
            cur["state"] = "running"
            cur["endedAt"] = None
        cur.setdefault("title", folder)
    elif name == "PermissionRequest":          # Codex: about to ask for approval
        cur.setdefault("title", folder)
        cur.setdefault("startedAt", now)
        cur["state"] = "permission"
    elif name == "Notification":               # Claude Code: permission prompt or idle notice
        msg = (ev.get("message") or "") + " " + (ev.get("notification_type") or "") + " " + (ev.get("title") or "")
        low = msg.lower()
        cur.setdefault("title", folder)
        cur.setdefault("startedAt", now)
        if "permission" in low or "approve" in low or "allow" in low:
            cur["state"] = "permission"
        elif "idle" in low or "waiting for your input" in low:
            cur["state"] = "done"
            cur["endedAt"] = now
    elif name in ("Stop", "Interrupt"):
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
