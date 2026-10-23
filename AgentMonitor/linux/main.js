// Claude Monitor — floating usage orb + chat activity cards (Linux / Windows build, Electron).
'use strict';
const { app, BrowserWindow, ipcMain, Menu, Tray, screen, shell, nativeImage, session, Notification } = require('electron');
const path = require('path');
const fs = require('fs');

// ---------- constants ----------
const NARROW_W = 150, WIDE_W = 240, ORB_H = 178, ORB_CENTER_FROM_TOP = 97, CARD_STEP = 50, MAX_CARDS = 5;
const MIN_SCALE = 0.6, MAX_SCALE = 2.5;
const REFRESH_MS = 60_000, POLL_MS = 6_000, LOCAL_POLL_MS = 2_000;
const CHROME_UA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0.0.0 Safari/537.36';
const PARTITION = 'persist:claude';
// Claude Code (CLI) writes one <pid>.json per running session here; we only ever read it.
const CLI_SESSIONS_DIR = path.join(require('os').homedir(), '.claude', 'sessions');

if (process.platform === 'linux') {
  app.commandLine.appendSwitch('enable-transparent-visuals');
  app.commandLine.appendSwitch('disable-gpu-compositing');
}
app.commandLine.appendSwitch('disable-features', 'CalculateNativeWinOcclusion');

const userData = () => app.getPath('userData');
const stateFile = () => path.join(userData(), 'state.json');
const logFile = () => path.join(userData(), 'monitor.log');

function log(s) {
  try { fs.appendFileSync(logFile(), `${new Date().toISOString()} ${s}\n`); } catch (e) {}
}

let state = { scale: 1, hidden: false, x: null, y: null, tasks: [], notify: true, style: 'classic' };
function loadState() {
  try { Object.assign(state, JSON.parse(fs.readFileSync(stateFile(), 'utf8'))); } catch (e) {}
  state.scale = Math.min(MAX_SCALE, Math.max(MIN_SCALE, Number(state.scale) || 1));
  if (!Array.isArray(state.tasks)) state.tasks = [];
}
let saveTimer = null;
function saveState() {
  clearTimeout(saveTimer);
  saveTimer = setTimeout(() => { try { fs.writeFileSync(stateFile(), JSON.stringify(state)); } catch (e) {} }, 300);
}

// ---------- orb window ----------
let orb = null, tray = null, fetcher = null, loginWin = null;
let lastPayload = null, lastSession = null, lastWeek = null, lastOK = null, source = '';
let refreshing = false, polling = false, promptedLogin = false, pageLoaded = false;
let dragInterval = null;

function orbSize() {
  const n = state.tasks.length, shown = Math.min(n, MAX_CARDS);
  let h = ORB_H;
  if (n > 0) h += 2 + shown * CARD_STEP + (n > MAX_CARDS ? 18 : 0);
  const w = n > 0 ? WIDE_W : NARROW_W;
  return { width: Math.round(w * state.scale), height: Math.round(h * state.scale) };
}

function createOrb() {
  const { width, height } = orbSize();
  orb = new BrowserWindow({
    width, height,
    x: state.x ?? undefined, y: state.y ?? undefined,
    frame: false, transparent: true, hasShadow: false, resizable: false, movable: false,
    minimizable: false, maximizable: false, fullscreenable: false,
    skipTaskbar: true, alwaysOnTop: true, show: false, focusable: process.platform !== 'win32',
    backgroundColor: '#00000000',
    webPreferences: { preload: path.join(__dirname, 'preload.js'), contextIsolation: true, nodeIntegration: false, backgroundThrottling: false }
  });
  orb.setAlwaysOnTop(true, 'screen-saver');
  orb.setVisibleOnAllWorkspaces(true, { visibleOnFullScreen: true });
  orb.setMenu(null);
  orb.loadFile(path.join(__dirname, 'orb.html'));
  orb.webContents.on('did-finish-load', () => {
    pageLoaded = true;
    orb.webContents.setZoomFactor(state.scale);
    js(`window.orbStyle && window.orbStyle(${JSON.stringify(state.style || 'classic')})`);
    js(`window.orbZoom && window.orbZoom(${state.scale})`);
    if (lastPayload) js(`window.orbUpdate && window.orbUpdate(${JSON.stringify(lastPayload)})`);
    pushTasks();
  });
  let shown = false;
  const firstShow = () => {
    if (shown || !orb) return;
    shown = true;
    if (state.x == null) placeDefault();
    ensureOnScreen();
    if (!state.hidden) orb.show();
  };
  orb.once('ready-to-show', firstShow);
  // Some X11 setups (e.g. XFCE over xrdp) never emit ready-to-show for transparent windows.
  orb.webContents.once('did-finish-load', () => setTimeout(firstShow, 300));
  setTimeout(firstShow, 3000);
  orb.on('closed', () => { orb = null; });
}

function js(code) { if (orb && pageLoaded) orb.webContents.executeJavaScript(code).catch(() => {}); }

function placeDefault() {
  const d = screen.getPrimaryDisplay().workArea;
  const { width, height } = orbSize();
  setPos(d.x + d.width - width - 24, d.y + 24);
}
function setPos(x, y) {
  state.x = Math.round(x); state.y = Math.round(y);
  if (orb) orb.setPosition(state.x, state.y);
  saveState();
}
function ensureOnScreen() {
  const { width } = orbSize();
  const cx = state.x + width / 2, cy = state.y + (ORB_CENTER_FROM_TOP * state.scale);
  const ok = screen.getAllDisplays().some(d => {
    const a = d.workArea; return cx >= a.x && cx <= a.x + a.width && cy >= a.y && cy <= a.y + a.height;
  });
  if (!ok) placeDefault();
}

/** Resize for the current scale / card count, keeping the orb centre fixed on screen. */
function relayout(oldScale) {
  if (!orb) return;
  const [bx, by] = orb.getPosition();
  const [bw] = orb.getSize();
  const centerX = bx + bw / 2, centerY = by + ORB_CENTER_FROM_TOP * oldScale;
  const { width, height } = orbSize();
  const x = Math.round(centerX - width / 2), y = Math.round(centerY - ORB_CENTER_FROM_TOP * state.scale);
  orb.setBounds({ x, y, width, height });
  state.x = x; state.y = y;
  saveState();
}

let zoomTimer = null;
function setScale(s) {
  s = Math.min(MAX_SCALE, Math.max(MIN_SCALE, s));
  if (Math.abs(s - state.scale) < 0.001) return;
  const old = state.scale;
  state.scale = s;
  relayout(old);
  if (orb) orb.webContents.setZoomFactor(s);
  clearTimeout(zoomTimer);
  zoomTimer = setTimeout(() => js(`window.orbZoom && window.orbZoom(${s})`), 150);
  saveState();
}

function send(payload) {
  lastPayload = payload;
  js(`window.orbUpdate && window.orbUpdate(${JSON.stringify(payload)})`);
}
function pushTasks() {
  const list = state.tasks.map(t => ({ id: t.id, src: t.src || 'web', title: t.title, state: t.state, bucket: t.bucket, note: t.note || '', startedAt: t.startedAt, waitingSince: t.waitingSince || null, endedAt: t.endedAt }));
  js(`window.orbTasks && window.orbTasks(${JSON.stringify(list)})`);
}
function setTasks(tasks) {
  const countChanged = tasks.length !== state.tasks.length;
  state.tasks = tasks;
  if (countChanged) relayout(state.scale);
  pushTasks();
  saveState();
}

// ---------- claude.ai session (hidden window shared by sign-in + reads) ----------
const USAGE_SCRIPT = `(async () => {
  try {
    const get = async (p) => {
      const r = await fetch(p, { credentials: 'include', headers: { 'accept': 'application/json' } });
      let j = null; try { j = await r.json(); } catch (e) {}
      return { status: r.status, ok: r.ok, json: j };
    };
    const o = await get('/api/organizations');
    if (!o.ok) return JSON.stringify({ error: 'orgs', status: o.status });
    const orgs = Array.isArray(o.json) ? o.json : [];
    if (!orgs.length) return JSON.stringify({ error: 'noorg', status: 401 });
    const rank = (x) => { const c = (x.capabilities || []).join(','); return c.includes('claude_max') ? 0 : c.includes('claude_pro') ? 1 : c.includes('chat') ? 2 : 3; };
    orgs.sort((a, b) => rank(a) - rank(b));
    let last = 0;
    for (const org of orgs) {
      const u = await get('/api/organizations/' + org.uuid + '/usage');
      last = u.status;
      if (u.ok && u.json && ('five_hour' in u.json || 'seven_day' in u.json)) return JSON.stringify({ data: u.json });
    }
    return JSON.stringify({ error: 'usage', status: last });
  } catch (e) { return JSON.stringify({ error: 'exception ' + e, status: 0 }); }
})()`;

const sessionsScript = (trackedIds) => `(async () => {
  const trackedIds = ${JSON.stringify(trackedIds)};
  try {
    const get = async (u) => { const r = await fetch(u, { credentials: 'include', headers: { accept: 'application/json' } }); if (!r.ok) throw 'http ' + r.status + ' ' + u; return r.json(); };
    const ms = (t) => { if (!t) return 0; const v = Date.parse(String(t).replace(/(\\.\\d{3})\\d+/, '$1')); return isNaN(v) ? 0 : v; };
    const orgs = await get('/api/organizations');
    const rank = (x) => { const c = (x.capabilities || []).join(','); return c.includes('claude_max') ? 0 : c.includes('claude_pro') ? 1 : c.includes('chat') ? 2 : 3; };
    orgs.sort((a, b) => rank(a) - rank(b));
    const org = orgs[0].uuid;
    const raw = await get('/api/organizations/' + org + '/chat_conversations?limit=40');
    const list = Array.isArray(raw) ? raw : (raw.data || []);
    const byId = new Map();
    for (const c of list) byId.set(c.uuid, c);
    const tracked = new Set(trackedIds);
    for (const id of tracked) {
      if (!byId.has(id)) { try { byId.set(id, await get('/api/organizations/' + org + '/chat_conversations/' + id)); } catch (e) {} }
    }
    const out = [];
    for (const c of byId.values()) {
      const live = (c.live_status || '').toLowerCase();
      const busy = !!live && !['done', 'idle', 'completed', 'settled', 'finished', 'stopped', 'none'].includes(live);
      if (!busy && !tracked.has(c.uuid)) continue;
      let req = 0;
      if (busy && c.workspace_session_id) {
        try {
          const r = await fetch('/v1/code/sessions/' + c.workspace_session_id, { credentials: 'include', headers: { 'anthropic-version': '2023-06-01' } });
          if (r.ok) { const d = await r.json(); const x = d.response_shape || d; req = (x.requires_action_details_list || []).length; }
        } catch (e) {}
      }
      out.push({ id: c.uuid, title: c.name || '', live, req, startedMs: ms(c.live_status_started_at), settledMs: ms(c.last_settled_at), url: '/chat/' + c.uuid });
    }
    return JSON.stringify({ sessions: out });
  } catch (e) { return JSON.stringify({ error: String(e) }); }
})()`;

let fetcherReady = false, fetcherLoading = null;
function getFetcher() {
  if (fetcher && !fetcher.isDestroyed()) return fetcher;
  fetcher = new BrowserWindow({ show: false, webPreferences: { partition: PARTITION, contextIsolation: true, nodeIntegration: false, backgroundThrottling: false } });
  fetcher.webContents.setUserAgent(CHROME_UA);
  fetcher.on('closed', () => { fetcher = null; fetcherReady = false; });
  fetcherReady = false;
  return fetcher;
}
async function ensureFetcherReady() {
  const w = getFetcher();
  if (fetcherReady && (w.webContents.getURL() || '').includes('claude.ai')) return true;
  if (fetcherLoading) return fetcherLoading;
  fetcherLoading = (async () => {
    try {
      await w.loadURL('https://claude.ai/api/organizations');
      fetcherReady = (w.webContents.getURL() || '').includes('claude.ai');
    } catch (e) { log('fetcher load failed: ' + e.message); fetcherReady = false; }
    fetcherLoading = null;
    return fetcherReady;
  })();
  return fetcherLoading;
}
function invalidateFetcher() { fetcherReady = false; }

async function runInClaude(script) {
  if (!(await ensureFetcherReady())) return null;
  try {
    const s = await getFetcher().webContents.executeJavaScript(script, true);
    return JSON.parse(s);
  } catch (e) { log('script failure: ' + e.message); fetcherReady = false; return null; }
}

// ---------- usage refresh ----------
async function refresh() {
  if (refreshing || loginWin) return;
  refreshing = true;
  try {
    const r = await runInClaude(USAGE_SCRIPT);
    if (r && r.data) { deliver(r.data); return; }
    const status = r ? (r.status || 0) : 0;
    if (r) log('usage error: ' + JSON.stringify(r));
    if (status === 401 || status === 403) {
      send({ status: 'login' });
      if (!promptedLogin) { promptedLogin = true; openLogin(); }
    } else {
      send({ status: 'error' });
    }
  } finally { refreshing = false; }
}
function deliver(d) {
  const win = (k) => d[k] ? { pct: d[k].utilization, resetsAt: d[k].resets_at } : null;
  lastSession = d.five_hour ? d.five_hour.utilization : 0;
  lastWeek = d.seven_day ? d.seven_day.utilization : 0;
  lastOK = new Date(); source = 'claude.ai';
  log(`fetch ok: five_hour=${lastSession} seven_day=${lastWeek}`);
  send({ status: 'ok', session: win('five_hour'), week: win('seven_day') });
}

// ---------- chat activity ----------
const DONE_WORDS = ['done', 'idle', 'completed', 'settled', 'finished', 'stopped', 'none'];
async function pollTasks() {
  if (polling || loginWin || !lastOK) return;
  polling = true;
  try {
    const tracked = state.tasks.filter(t => t.src !== 'cli' && t.state !== 'done').map(t => t.id);
    const r = await runInClaude(sessionsScript(tracked));
    if (!r) return;
    if (r.error) { log('sessions error: ' + r.error); return; }
    ingest(r.sessions || []);
  } finally { polling = false; }
}
function ingest(list) {
  const now = Date.now();
  let changed = false;
  const tasks = state.tasks.slice();
  for (const s of list) {
    const live = (s.live || '').toLowerCase();
    const busy = !!live && !DONE_WORDS.includes(live);
    const perm = (s.req || 0) > 0 || /permission|approv|action|input|wait/.test(live);
    const title = (s.title || '').trim() || 'Untitled chat';
    const i = tasks.findIndex(t => t.id === s.id);
    if (i >= 0) {
      const t = { ...tasks[i] };
      const before = `${t.state}|${t.title}|${t.bucket}`;
      if (busy) {
        if (t.state === 'done') { t.startedAt = s.startedMs || now; t.endedAt = null; }
        else if (s.startedMs && Math.abs(s.startedMs - t.startedAt) > 60_000) t.startedAt = s.startedMs;
        t.state = perm ? 'permission' : 'running';
        t.idleSeen = 0;
      } else if (t.state !== 'done') {
        t.idleSeen = (t.idleSeen || 0) + 1;
        if (t.idleSeen >= 2) { t.state = 'done'; t.endedAt = s.settledMs > t.startedAt ? s.settledMs : now; }
      }
      t.title = title; t.bucket = live; if (s.url) t.url = s.url;
      if (before !== `${t.state}|${t.title}|${t.bucket}`) { changed = true; log(`chat '${title}' → ${t.state} (${live})`); }
      tasks[i] = t;
    } else if (busy) {
      tasks.push({ id: s.id, title, url: s.url || '', state: perm ? 'permission' : 'running', bucket: live, startedAt: s.startedMs || now, endedAt: null, idleSeen: 0 });
      changed = true;
      log(`chat '${title}' started (${live}, req=${s.req})`);
    }
  }
  if (changed) setTasks(tasks);
}
function cardAction(id, action) {
  const i = state.tasks.findIndex(t => t.id === id);
  if (i < 0) return;
  const t = state.tasks[i];
  if (t.src === 'cli') focusCliTerminal(t);
  else openChat(t);
  if (action === 'check') setTasks(state.tasks.filter((_, k) => k !== i));
}
async function openChat(t) {
  const p = t.url || ('/chat/' + t.id);
  // Try the desktop app's URL scheme first; fall back to the web app.
  try { await shell.openExternal('claude://claude.ai' + p); log('open chat via claude:// ' + p); }
  catch (e) { log('claude:// unavailable, opening web ' + p); shell.openExternal('https://claude.ai' + p); }
}
// ---------- local Claude Code sessions (this user, this computer) ----------
let cliSessions = [];   // every live CLI session, for the menu
let cliPolling = false;

function notify(title, body) {
  if (!state.notify || !Notification.isSupported()) return;
  try { new Notification({ title, body }).show(); } catch (e) {}
}
/** True if pid is alive and (when known) is the same process that wrote the file, not a reused pid. */
function procAlive(pid, procStart) {
  try {
    const stat = fs.readFileSync(`/proc/${pid}/stat`, 'utf8');
    if (!procStart) return true;
    const fields = stat.slice(stat.lastIndexOf(')') + 2).split(' ');
    return fields[19] === String(procStart);   // field 22 of /proc/pid/stat = start time
  } catch (e) { return false; }
}
function ttyOf(pid) {
  try { const t = fs.readlinkSync(`/proc/${pid}/fd/0`); return /^\/dev\/pts\/\d+$/.test(t) ? t : ''; } catch (e) { return ''; }
}

// Raise the terminal window a session runs in. All gnome-terminal windows share one process, so we
// find the window by briefly setting a unique title on the session's tty (an OSC escape: changes the
// title only, no text or input), then restore the title and ask the window manager to activate it.
const WINTOOL = path.join(__dirname, 'tools', 'wintool');
const { execFile } = require('child_process');
const runWintool = (...args) => new Promise((resolve) => {
  execFile(WINTOOL, args, { timeout: 3000 }, (err, out) => resolve(err ? null : out));
});
const setTitle = (tty, title) => fs.writeFileSync(tty, `\x1b]0;${String(title).replace(/[\x00-\x1f\x7f]/g, '')}\x07`, { flag: 'a' });
let focusing = false;
async function focusCliTerminal(t) {
  if (focusing) return;
  const tty = t.tty || '';
  if (!/^\/dev\/pts\/\d+$/.test(tty) || !fs.existsSync(WINTOOL)) {
    log(`cannot focus '${t.title}': tty=${tty} wintool=${fs.existsSync(WINTOOL)}`);
    notify('Claude Monitor', `Couldn't find the terminal for "${t.title}".`);
    return;
  }
  focusing = true;
  try {
    const parse = (out) => (out || '').split('\n').filter(Boolean).map(l => { const i = l.indexOf('\t'); return [l.slice(0, i), l.slice(i + 1)]; });
    const before = new Map(parse(await runWintool('list')));
    const mark = `claude-monitor-${process.pid}-${Date.now()}`;
    try { setTitle(tty, mark); } catch (e) { log('focus: cannot write tty ' + e.message); notify('Claude Monitor', `The terminal for "${t.title}" is gone.`); return; }
    let win = null;
    for (let i = 0; i < 30 && !win; i++) {
      const hit = parse(await runWintool('list')).find(([, title]) => title === mark);
      if (hit) win = hit[0]; else await new Promise(r => setTimeout(r, 50));
    }
    try { setTitle(tty, (win && before.get(win)) || t.title); } catch (e) {}
    if (win) { await runWintool('activate', win); log(`focused terminal ${win} for '${t.title}'`); }
    else { log(`focus: no window for ${tty}`); notify('Claude Monitor', `Couldn't find the terminal window for "${t.title}" (it may be inside tmux, SSH or an IDE).`); }
  } finally { focusing = false; }
}

function readCliSessions() {
  let files;
  try { files = fs.readdirSync(CLI_SESSIONS_DIR); } catch (e) { return []; }
  const out = [];
  for (const f of files) {
    if (!/^\d+\.json$/.test(f)) continue;
    try {
      const d = JSON.parse(fs.readFileSync(path.join(CLI_SESSIONS_DIR, f), 'utf8'));
      if (d && d.sessionId && d.pid && procAlive(d.pid, d.procStart)) { d.tty = ttyOf(d.pid); out.push(d); }
    } catch (e) {}
  }
  return out;
}
function pollCli() {
  if (cliPolling) return;
  cliPolling = true;
  try { ingestCli(readCliSessions()); } catch (e) { log('cli poll error: ' + e.message); }
  finally { cliPolling = false; }
}
function ingestCli(list) {
  cliSessions = list;
  const now = Date.now();
  let changed = false;
  const tasks = state.tasks.slice();
  const seen = new Set();
  for (const d of list) {
    const id = 'cli:' + d.sessionId;
    seen.add(id);
    const status = String(d.status || '').toLowerCase();
    const perm = status === 'waiting';
    const busy = status === 'busy';
    const title = (d.name || path.basename(d.cwd || '') || 'Claude Code').trim();
    const note = perm ? (d.waitingFor || 'input needed') : '';
    const at = d.statusUpdatedAt || now;
    const i = tasks.findIndex(t => t.id === id);
    if (busy || perm) {
      const next = perm ? 'permission' : 'running';
      if (i < 0) {
        tasks.push({ id, src: 'cli', title, cwd: d.cwd || '', pid: d.pid, tty: d.tty, state: next, bucket: status, note, startedAt: at, waitingSince: perm ? at : null, endedAt: null });
        changed = true;
        log(`cli '${title}' ${next}`);
        if (perm) notify('Claude Code needs you', `${title}: ${note}`);
        continue;
      }
      const t = { ...tasks[i] };
      if (t.state === 'done') { t.startedAt = at; t.endedAt = null; }
      if (perm && t.state !== 'permission') { t.waitingSince = at; notify('Claude Code needs you', `${title}: ${note}`); }
      if (!perm) t.waitingSince = null;
      if (t.state !== next || t.title !== title || t.note !== note) { changed = true; log(`cli '${title}' → ${next} ${note}`); }
      Object.assign(t, { state: next, title, note, bucket: status, cwd: d.cwd || t.cwd, pid: d.pid, tty: d.tty || t.tty });
      tasks[i] = t;
    } else if (i >= 0 && tasks[i].state !== 'done') {
      tasks[i] = { ...tasks[i], state: 'done', bucket: status, note: '', waitingSince: null, endedAt: at, title };
      changed = true;
      log(`cli '${title}' finished`);
      notify('Claude Code finished', title);
    }
  }
  // Sessions whose process has exited while still working.
  for (let i = 0; i < tasks.length; i++) {
    const t = tasks[i];
    if (t.src === 'cli' && !seen.has(t.id) && t.state !== 'done') {
      tasks[i] = { ...t, state: 'done', note: 'session closed', waitingSince: null, endedAt: now };
      changed = true;
      log(`cli '${t.title}' session closed`);
    }
  }
  if (changed) setTasks(tasks);
}
function cliMenu() {
  const label = { busy: '● working', waiting: '⚑ needs you', idle: '○ idle', shell: '○ idle (shell running)' };
  const items = cliSessions
    .slice().sort((a, b) => (b.statusUpdatedAt || 0) - (a.statusUpdatedAt || 0))
    .map(d => ({
      label: `${label[d.status] || d.status}  ·  ${d.name || path.basename(d.cwd || '')}${d.status === 'waiting' && d.waitingFor ? ' — ' + d.waitingFor : ''}`,
      click: () => focusCliTerminal({ title: d.name || path.basename(d.cwd || ''), tty: d.tty })
    }));
  return { label: `Claude Code on this computer (${cliSessions.length})`, submenu: items.length ? items : [{ label: 'No running sessions', enabled: false }] };
}

function clearFinished() { setTasks(state.tasks.filter(t => t.state !== 'done')); }

// ---------- sign-in window ----------
function openLogin() {
  if (loginWin && !loginWin.isDestroyed()) { loginWin.show(); loginWin.focus(); return; }
  log('opening sign-in window');
  loginWin = new BrowserWindow({
    width: 480, height: 760, title: 'Sign in to Claude (used only to read usage)', autoHideMenuBar: true,
    webPreferences: { partition: PARTITION, contextIsolation: true, nodeIntegration: false }
  });
  loginWin.webContents.setUserAgent(CHROME_UA);
  loginWin.webContents.setWindowOpenHandler(() => ({ action: 'allow', overrideBrowserWindowOptions: { width: 500, height: 640, autoHideMenuBar: true, webPreferences: { partition: PARTITION } } }));
  loginWin.loadURL('https://claude.ai/login');
  let closing = false;
  const check = async () => {
    if (!loginWin || loginWin.isDestroyed() || closing) return;
    if (!(loginWin.webContents.getURL() || '').includes('claude.ai')) return;
    try {
      const ok = await loginWin.webContents.executeJavaScript(`fetch('/api/organizations',{credentials:'include'}).then(r => r.ok ? r.json() : null).then(j => Array.isArray(j) && j.length > 0).catch(() => false)`, true);
      if (ok) { closing = true; log('signed in'); setTimeout(() => { if (loginWin && !loginWin.isDestroyed()) loginWin.close(); }, 800); }
    } catch (e) {}
  };
  const timer = setInterval(check, 2500);
  loginWin.webContents.on('did-finish-load', () => setTimeout(check, 1000));
  loginWin.on('closed', () => {
    clearInterval(timer);
    loginWin = null;
    invalidateFetcher();
    log('sign-in window closed');
    setTimeout(refresh, 300);
  });
}

// ---------- launch at login ----------
const autostartDesktop = () => path.join(app.getPath('home'), '.config', 'autostart', 'claude-monitor.desktop');
function launchAtLoginEnabled() {
  if (process.platform === 'linux') return fs.existsSync(autostartDesktop());
  return app.getLoginItemSettings().openAtLogin;
}
function toggleLaunchAtLogin() {
  const on = !launchAtLoginEnabled();
  if (process.platform === 'linux') {
    if (on) {
      const exec = `${JSON.stringify(process.execPath)} ${JSON.stringify(path.join(__dirname))}`;
      fs.mkdirSync(path.dirname(autostartDesktop()), { recursive: true });
      fs.writeFileSync(autostartDesktop(), `[Desktop Entry]\nType=Application\nName=Claude Monitor\nExec=${exec}\nX-GNOME-Autostart-enabled=true\nTerminal=false\n`);
    } else { try { fs.unlinkSync(autostartDesktop()); } catch (e) {} }
  } else {
    app.setLoginItemSettings({ openAtLogin: on, path: process.execPath, args: [path.join(__dirname)] });
  }
}

// ---------- menus ----------
function buildMenu() {
  const fmt = v => (v == null ? '--' : Math.round(v) + '%');
  const items = [
    { label: `Session ${fmt(lastSession)}   ·   Week ${fmt(lastWeek)}`, enabled: false },
  ];
  if (lastOK) items.push({ label: `Source: ${source} · updated ${lastOK.toTimeString().slice(0, 5)}`, enabled: false });
  items.push({ type: 'separator' });
  items.push({ label: 'Refresh now', click: refresh });
  items.push({ label: orb && orb.isVisible() ? 'Hide orb' : 'Show orb', click: toggleOrb });
  items.push({
    label: 'Size', submenu: [
      { label: 'Tip: scroll or pinch on the orb to resize', enabled: false }, { type: 'separator' },
      { label: 'Bigger', click: () => setScale(state.scale * 1.12) },
      { label: 'Smaller', click: () => setScale(state.scale / 1.12) }, { type: 'separator' },
      ...[['Small', 0.8], ['Medium', 1], ['Large', 1.25], ['Extra large', 1.5], ['Huge', 2]].map(([label, s]) => ({ label, type: 'radio', checked: Math.abs(state.scale - s) < 0.01, click: () => setScale(s) }))
    ]
  });
  items.push({
    label: 'Style', submenu: [['Classic orb', 'classic'], ["Witch's cauldron 🎃", 'witch']].map(([label, key]) =>
      ({ label, type: 'radio', checked: (state.style || 'classic') === key, click: () => setStyle(key) }))
  });
  items.push({ label: 'Move to top-right corner', click: () => { placeDefault(); if (orb) orb.show(); } });
  items.push(cliMenu());
  if (state.tasks.some(t => t.state === 'done')) items.push({ label: 'Clear finished chats', click: clearFinished });
  items.push({ type: 'separator' });
  items.push({ label: lastOK ? 'Sign in again…' : 'Sign in to claude.ai…', click: () => { promptedLogin = true; openLogin(); } });
  items.push({ label: 'Desktop notifications (Claude Code)', type: 'checkbox', checked: state.notify !== false, click: () => { state.notify = !state.notify; saveState(); } });
  items.push({ label: 'Launch at login', type: 'checkbox', checked: launchAtLoginEnabled(), click: toggleLaunchAtLogin });
  items.push({ type: 'separator' });
  items.push({ label: 'Quit', click: () => app.quit() });
  return Menu.buildFromTemplate(items);
}
function setStyle(key) {
  state.style = key === 'classic' ? 'classic' : 'witch';
  saveState();
  js(`window.orbStyle && window.orbStyle(${JSON.stringify(state.style)})`);
}
function toggleOrb() {
  if (!orb) return;
  if (orb.isVisible()) { orb.hide(); state.hidden = true; } else { orb.show(); state.hidden = false; }
  saveState();
}

function createTray() {
  const icon = nativeImage.createFromPath(path.join(__dirname, 'assets', process.platform === 'win32' ? 'tray.ico' : 'tray.png'));
  tray = new Tray(icon);
  tray.setToolTip('Claude Monitor');
  tray.on('click', () => tray.popUpContextMenu(buildMenu()));
  tray.on('right-click', () => tray.popUpContextMenu(buildMenu()));
}

// ---------- ipc from the orb page ----------
ipcMain.on('orb:menu', () => { if (orb) buildMenu().popup({ window: orb }); });
ipcMain.on('orb:double', () => { if (!lastOK && promptedLogin) openLogin(); else refresh(); });
ipcMain.on('orb:resize', (_, f) => setScale(state.scale * f));
ipcMain.on('orb:card', (_, { id, action }) => cardAction(id, action));
ipcMain.on('orb:drag-start', (_, { ox, oy }) => {
  // ox/oy: cursor offset inside the window (CSS px × zoom = device px); poll the cursor until drag-end.
  clearInterval(dragInterval);
  dragInterval = setInterval(() => {
    if (!orb) return;
    const c = screen.getCursorScreenPoint();
    orb.setPosition(Math.round(c.x - ox), Math.round(c.y - oy));
  }, 16);
});
ipcMain.on('orb:drag-end', () => {
  clearInterval(dragInterval); dragInterval = null;
  if (orb) { const [x, y] = orb.getPosition(); state.x = x; state.y = y; saveState(); }
});

// ---------- app lifecycle ----------
const single = app.requestSingleInstanceLock();
if (!single) { app.quit(); }
else {
  app.on('second-instance', () => { if (orb) { orb.show(); state.hidden = false; saveState(); } });
  app.whenReady().then(() => {
    loadState();
    log('app started');
    session.fromPartition(PARTITION).setUserAgent(CHROME_UA);
    // Linux needs a moment after ready before a transparent window renders correctly.
    setTimeout(() => {
      createOrb();
      createTray();
      if (!process.env.CM_TEST) {
        refresh();
        setInterval(refresh, REFRESH_MS);
        setTimeout(pollTasks, 2000);
        setInterval(pollTasks, POLL_MS);
        pollCli();
        setInterval(pollCli, LOCAL_POLL_MS);
      }
      screen.on('display-metrics-changed', ensureOnScreen);
    }, process.platform === 'linux' ? 400 : 0);
  });
  app.on('window-all-closed', (e) => { /* keep running from the tray */ });
}
