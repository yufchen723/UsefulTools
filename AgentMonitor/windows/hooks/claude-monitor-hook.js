#!/usr/bin/env node
// Claude Code hook for Claude Monitor (Windows / Node build).
// Claude Code runs this on session events and pipes the event JSON on stdin; we keep one small
// JSON file per session so the orb can show terminal sessions as cards. Never prints, never fails loudly.
'use strict';
const fs = require('fs');
const path = require('path');
const os = require('os');

function stateDir() {
  const base = process.platform === 'win32'
    ? (process.env.APPDATA || path.join(os.homedir(), 'AppData', 'Roaming'))
    : process.platform === 'darwin'
      ? path.join(os.homedir(), 'Library', 'Application Support')
      : (process.env.XDG_CONFIG_HOME || path.join(os.homedir(), '.config'));
  return path.join(base, 'claude-monitor', 'code-sessions');
}

function main(raw) {
  let ev;
  try { ev = JSON.parse(raw); } catch (e) { return; }
  const sid = ev.session_id;
  if (!sid) return;
  const name = ev.hook_event_name || '';
  const dir = stateDir();
  fs.mkdirSync(dir, { recursive: true });
  const file = path.join(dir, sid + '.json');
  const now = Date.now();
  let cur = {};
  try { cur = JSON.parse(fs.readFileSync(file, 'utf8')); } catch (e) {}

  const cwd = ev.cwd || cur.cwd || '';
  const folder = cwd.split(/[\\/]+/).filter(Boolean).pop() || cwd;
  cur.id = cur.id || sid;
  cur.kind = 'code-local';
  cur.cwd = cwd;
  cur.pid = process.ppid;   // the claude process; lets the orb drop sessions whose process is gone
  cur.updatedAt = now;

  if (name === 'UserPromptSubmit') {
    const prompt = String(ev.prompt || '').split(/\s+/).join(' ').trim();
    if (prompt) cur.prompt = prompt.slice(0, 80);
    cur.title = folder + (cur.prompt ? ' · ' + cur.prompt.slice(0, 48) : '');
    if (cur.state !== 'running' && cur.state !== 'permission') { cur.startedAt = now; cur.endedAt = null; }
    cur.state = 'running';
  } else if (['PreToolUse', 'PostToolUse', 'SubagentStop', 'PreCompact'].includes(name)) {
    if (cur.state !== 'running') { cur.startedAt = cur.startedAt || now; cur.state = 'running'; cur.endedAt = null; }
    cur.title = cur.title || folder;
  } else if (name === 'Notification') {
    const low = [ev.message, ev.notification_type, ev.title].filter(Boolean).join(' ').toLowerCase();
    cur.title = cur.title || folder;
    cur.startedAt = cur.startedAt || now;
    if (/permission|approve|allow/.test(low)) cur.state = 'permission';
    else if (/idle|waiting for your input/.test(low)) { cur.state = 'done'; cur.endedAt = now; }
  } else if (name === 'Stop') {
    if (ev.stop_hook_active) return;
    cur.title = cur.title || folder;
    cur.startedAt = cur.startedAt || now;
    cur.state = 'done';
    cur.endedAt = now;
  } else if (name === 'SessionEnd') {
    if (cur.state !== 'done') { try { fs.unlinkSync(file); } catch (e) {} return; }
    cur.pid = null;
  } else {
    return;
  }

  const tmp = file + '.tmp';
  try { fs.writeFileSync(tmp, JSON.stringify(cur)); fs.renameSync(tmp, file); } catch (e) {}
}

let buf = '';
process.stdin.setEncoding('utf8');
process.stdin.on('data', d => { buf += d; });
process.stdin.on('end', () => { try { main(buf); } catch (e) {} });
