// Claude Usage Orb — a floating, draggable desktop orb that shows Claude plan usage
// (current 5-hour session on the left, weekly on the right), and — when OpenAI Codex
// is installed — Codex plan usage too (left half Claude, right half Codex, top row the
// 5-hour window, bottom row the week).
// Build with ../build.sh

import Cocoa
import WebKit
import SQLite3

let kFrameName   = "ClaudeUsageOrbFrame"
let kScaleKey    = "ClaudeUsageOrbScale"
let kHiddenKey   = "ClaudeUsageOrbHidden"
let kStyleKey    = "ClaudeUsageOrbStyle"     // "classic" | "witch" | "dual"
let kAgentLabel  = "com.yufan.claude-usage-orb"
let refreshEvery: TimeInterval = 60
let minScale: CGFloat = 0.6
let maxScale: CGFloat = 2.5
let safariUA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"

var launchAgentURL: URL {
    FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/LaunchAgents/\(kAgentLabel).plist")
}

// MARK: - Transparent overlay that turns mouse input into drag / menu / clicks

final class OrbOverlay: NSView {
    var onRightClick: ((NSEvent) -> Void)?
    var onDoubleClick: (() -> Void)?
    var onHover: ((Bool) -> Void)?
    var onResize: ((CGFloat) -> Void)?          // multiplicative size change
    var isOrbArea: ((NSPoint) -> Bool)?         // point in view coords → true if over the orb
    var onCardClick: ((NSPoint) -> Void)?       // point in view coords, task-card area
    private var tracking: NSTrackingArea?
    private var pendingCardClick: NSPoint?

    // Scroll up / swipe up on the orb = bigger, down = smaller.
    override func scrollWheel(with event: NSEvent) {
        var dy = event.scrollingDeltaY
        if event.isDirectionInvertedFromDevice { dy = -dy }
        if !event.hasPreciseScrollingDeltas { dy *= 6 }
        guard dy != 0 else { return }
        onResize?(min(1.2, max(0.83, 1 + dy * 0.006)))
    }
    // Trackpad pinch.
    override func magnify(with event: NSEvent) {
        onResize?(min(1.2, max(0.83, 1 + event.magnification)))
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = tracking { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: bounds,
                               options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                               owner: self, userInfo: nil)
        addTrackingArea(t)
        tracking = t
    }
    override func mouseEntered(with event: NSEvent) { onHover?(true) }
    override func mouseExited(with event: NSEvent) { onHover?(false) }

    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.control) { onRightClick?(event); return }
        let p = convert(event.locationInWindow, from: nil)
        if isOrbArea?(p) ?? true {
            pendingCardClick = nil
            if event.clickCount >= 2 { onDoubleClick?(); return }
            window?.performDrag(with: event)
        } else {
            pendingCardClick = p
        }
    }
    override func mouseUp(with event: NSEvent) {
        guard let start = pendingCardClick else { return }
        pendingCardClick = nil
        let p = convert(event.locationInWindow, from: nil)
        if hypot(p.x - start.x, p.y - start.y) < 6 { onCardClick?(p) }
    }
    override func rightMouseDown(with event: NSEvent) { onRightClick?(event) }
}

final class OrbPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

// MARK: - The floating orb window

let orbAreaHeight: CGFloat = 178        // CSS px of the orb + countdown pills
let orbCenterFromTop: CGFloat = 97      // CSS px from the top of the window to the orb's centre
let codexExtraHeight: CGFloat = 26      // the 2×2 pill grid + legend in Claude + Codex mode (see .quad in orb.html)
let narrowWidth: CGFloat = 150
let wideWidth: CGFloat = 240            // when task cards are showing
let cardStep: CGFloat = 50              // card height 44 + gap 6
let maxCards = 5

final class OrbWindowController: NSObject, WKNavigationDelegate {
    let panel: OrbPanel
    let webView: WKWebView
    let overlay = OrbOverlay()
    private(set) var scale: CGFloat
    private var pageLoaded = false
    private var lastPayload: String?
    private var allTasks: [[String: Any]] = []
    private var lastTasks: String?
    private var taskCount = 0
    private var hovering = false
    private var zoomWork: DispatchWorkItem?
    private(set) var style: String = UserDefaults.standard.string(forKey: kStyleKey) ?? "classic"
    private(set) var quad = false            // Claude + Codex mode: taller orb area
    private var areaHeight: CGFloat { orbAreaHeight + (quad ? codexExtraHeight : 0) }
    private var centerFromTop: CGFloat { orbCenterFromTop + (quad ? codexExtraHeight : 0) }

    init(scale: CGFloat) {
        self.scale = scale
        let size = NSSize(width: narrowWidth * scale, height: orbAreaHeight * scale)
        panel = OrbPanel(contentRect: NSRect(origin: .zero, size: size),
                         styleMask: [.borderless, .nonactivatingPanel],
                         backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.isMovable = true

        let cfg = WKWebViewConfiguration()
        cfg.websiteDataStore = .nonPersistent()
        webView = WKWebView(frame: NSRect(origin: .zero, size: size), configuration: cfg)
        webView.setValue(false, forKey: "drawsBackground")
        webView.autoresizingMask = [.width, .height]
        webView.pageZoom = scale

        let container = NSView(frame: NSRect(origin: .zero, size: size))
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.clear.cgColor
        container.addSubview(webView)
        overlay.frame = container.bounds
        overlay.autoresizingMask = [.width, .height]
        container.addSubview(overlay)
        panel.contentView = container

        super.init()
        webView.navigationDelegate = self
        if let url = Bundle.main.url(forResource: "orb", withExtension: "html") {
            webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        }

        overlay.onHover = { [weak self] h in
            self?.hovering = h
            self?.js("window.orbHover && window.orbHover(\(h))")
        }
        overlay.isOrbArea = { [weak self] p in
            guard let self = self else { return true }
            return p.y >= self.overlay.bounds.height - self.areaHeight * self.scale
        }

        // Restore the last position (size always follows the chosen scale).
        if panel.setFrameUsingName(kFrameName) {
            let f = panel.frame
            panel.setFrame(NSRect(x: f.midX - size.width / 2, y: f.maxY - size.height, width: size.width, height: size.height), display: false)
        } else {
            placeDefault()
        }
        panel.setFrameAutosaveName(kFrameName)
        ensureOnScreen()
    }

    func placeDefault() {
        guard let vf = NSScreen.main?.visibleFrame else { return }
        let s = panel.frame.size
        panel.setFrameOrigin(NSPoint(x: vf.maxX - s.width - 24, y: vf.maxY - s.height - 24))
    }

    func ensureOnScreen() {
        let f = panel.frame
        let orbRect = NSRect(x: f.midX - 50, y: f.maxY - areaHeight * scale, width: 100, height: areaHeight * scale)
        let visible = NSScreen.screens.contains { $0.visibleFrame.intersects(orbRect) }
        if !visible { placeDefault() }
    }

    func show() { panel.orderFrontRegardless() }
    func hide() { panel.orderOut(nil) }
    var isVisible: Bool { panel.isVisible }

    /// Size for the current scale and number of task cards, keeping the orb itself fixed on screen.
    private func relayout(oldScale: CGFloat, oldCenterFromTop: CGFloat? = nil) {
        let old = panel.frame
        let shown = min(taskCount, maxCards)
        var h = areaHeight
        if taskCount > 0 { h += 2 + CGFloat(shown) * cardStep + (taskCount > maxCards ? 18 : 0) }
        let w = taskCount > 0 ? wideWidth : narrowWidth
        let size = NSSize(width: w * scale, height: h * scale)
        let orbCenterY = old.maxY - (oldCenterFromTop ?? centerFromTop) * oldScale
        let top = orbCenterY + centerFromTop * scale
        panel.setFrame(NSRect(x: old.midX - size.width / 2, y: top - size.height, width: size.width, height: size.height), display: true)
    }

    /// Switch between the Claude-only layout and the Claude + Codex layout (taller pill area).
    func setQuad(_ on: Bool) {
        guard on != quad else { return }
        let oldCenter = centerFromTop
        quad = on
        relayout(oldScale: scale, oldCenterFromTop: oldCenter)
        ensureOnScreen()
    }

    func setScale(_ s: CGFloat) {
        let oldScale = scale
        scale = s
        relayout(oldScale: oldScale)
        webView.pageZoom = s
        // Re-render the canvas at the new resolution once resizing pauses.
        zoomWork?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.js("window.orbZoom && window.orbZoom(\(s))") }
        zoomWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: w)
        UserDefaults.standard.set(Double(s), forKey: kScaleKey)
    }

    func setStyle(_ s: String) {
        guard ["classic", "witch", "dual"].contains(s) else { return }
        style = s
        setQuad(s == "dual")
        UserDefaults.standard.set(s, forKey: kStyleKey)
        js("window.orbStyle && window.orbStyle('\(s)')")
        setTasks(allTasks)
    }

    func send(_ payload: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let s = String(data: data, encoding: .utf8) else { return }
        lastPayload = s
        if pageLoaded { js("window.orbUpdate && window.orbUpdate(\(s))") }
    }

    func setTasks(_ tasks: [[String: Any]]) {
        allTasks = tasks
        let tasks = tasks.filter { task in
            let kind = task["kind"] as? String ?? "chat"
            return style == "dual" || (kind != "codex-local" && kind != "codex-desktop")
        }
        guard let data = try? JSONSerialization.data(withJSONObject: tasks),
              let s = String(data: data, encoding: .utf8) else { return }
        lastTasks = s
        if tasks.count != taskCount {
            taskCount = tasks.count
            relayout(oldScale: scale)
        }
        js("window.orbTasks && window.orbTasks(\(s))")
    }

    /// Ask the page which card / button sits under a click (view coords → CSS px).
    func cardAction(at p: NSPoint, _ done: @escaping (String, String) -> Void) {
        let x = p.x / scale
        let y = (overlay.bounds.height - p.y) / scale
        webView.evaluateJavaScript("window.orbClickAt ? window.orbClickAt(\(x), \(y)) : null") { v, _ in
            guard let s = v as? String, let d = s.data(using: .utf8),
                  let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: String],
                  let id = o["id"], let action = o["action"] else { return }
            done(id, action)
        }
    }

    private func js(_ code: String) {
        guard pageLoaded else { return }
        webView.evaluateJavaScript(code, completionHandler: nil)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        pageLoaded = true
        js("window.orbStyle && window.orbStyle('\(style)')")
        js("window.orbZoom && window.orbZoom(\(scale))")
        if let p = lastPayload { js("window.orbUpdate && window.orbUpdate(\(p))") }
        if let t = lastTasks { js("window.orbTasks && window.orbTasks(\(t))") }
        if hovering { js("window.orbHover && window.orbHover(true)") }
    }
}

// MARK: - Usage source 1: claude.ai web session (same numbers as Settings → Usage)

enum FetchOutcome {
    case ok([String: Any])
    case needLogin
    case failed(String)
}

func orbLog(_ s: String) {
    let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/ClaudeUsageOrb")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let url = dir.appendingPathComponent("orb.log")
    let line = "\(ISO8601DateFormatter().string(from: Date())) \(s)\n"
    if let h = try? FileHandle(forWritingTo: url) {
        h.seekToEndOfFile()
        h.write(line.data(using: .utf8)!)
        try? h.close()
    } else {
        try? line.write(to: url, atomically: true, encoding: .utf8)
    }
}

let claudeUsageJS = """
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
        if (u.ok && u.json && ('five_hour' in u.json || 'seven_day' in u.json)) {
          return JSON.stringify({ data: u.json, org: org.name || '' });
        }
      }
      return JSON.stringify({ error: 'usage', status: last });
    } catch (e) {
      return JSON.stringify({ error: 'exception ' + e, status: 0 });
    }
    """

/// A site the orb can sign in to and read usage from through a hidden web view.
struct WebSite {
    let name: String        // shown in the menu / log
    let host: String        // cookie domain suffix
    let readyURL: String    // cheap page that proves the session is alive
    let loginURL: String
    let checkJS: String     // async JS → 'ok' when signed in
    let usageJS: String     // async JS → JSON {data} or {error, status}

    static let claude = WebSite(
        name: "claude.ai", host: "claude.ai",
        readyURL: "https://claude.ai/api/organizations", loginURL: "https://claude.ai/login",
        checkJS: "try { const r = await fetch('/api/organizations', {credentials:'include'}); if (!r.ok) return 'http ' + r.status; const j = await r.json(); return (Array.isArray(j) && j.length) ? 'ok' : 'empty'; } catch (e) { return 'err ' + e; }",
        usageJS: claudeUsageJS)


}

/// One web view per site, shared by sign-in and usage reads, so cookies and
/// Cloudflare clearance are always the same ones.
final class WebSession: NSObject, WKNavigationDelegate, WKUIDelegate, NSWindowDelegate {
    let site: WebSite
    let webView: WKWebView
    private let hostWindow: NSWindow
    fileprivate var ready = false
    fileprivate var loading = false
    fileprivate var waiters: [(Bool) -> Void] = []
    fileprivate var popups: [(WKWebView, NSWindow)] = []
    fileprivate var loginWindow: NSWindow?
    fileprivate var statusLabel: NSTextField?
    fileprivate var pollTimer: Timer?
    fileprivate var closingLogin = false
    var onLoginFinished: (() -> Void)?
    var isLoginOpen: Bool { loginWindow != nil }

    init(site: WebSite) {
        self.site = site
        let cfg = WKWebViewConfiguration()
        cfg.websiteDataStore = .default()
        cfg.preferences.javaScriptCanOpenWindowsAutomatically = true
        webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 480, height: 700), configuration: cfg)
        webView.customUserAgent = safariUA
        hostWindow = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: 480, height: 700),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        hostWindow.isReleasedWhenClosed = false
        super.init()
        webView.navigationDelegate = self
        webView.uiDelegate = self
        hostWindow.contentView = webView
    }
}

extension WebSession {
    func invalidate() { if loginWindow == nil { ready = false } }

    private var onClaude: Bool { webView.url?.host?.hasSuffix(site.host) == true }

    private func ensureReady(_ done: @escaping (Bool) -> Void) {
        if loginWindow != nil { done(onClaude); return }
        if ready && onClaude { done(true); return }
        waiters.append(done)
        if loading { return }
        loading = true
        webView.load(URLRequest(url: URL(string: site.readyURL)!))
    }

    private func finish(_ ok: Bool) {
        loading = false
        ready = ok
        let w = waiters
        waiters = []
        w.forEach { $0(ok) }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        orbLog("loaded \(webView.url?.host ?? "-")\(webView.url?.path ?? "")")
        if loading { finish(onClaude) }
        if loginWindow != nil { DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.checkSignedIn() } }
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        orbLog("nav fail: \(error.localizedDescription)")
        if loading { finish(false) }
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        orbLog("nav fail (provisional): \(error.localizedDescription)")
        if loading { finish(false) }
    }

    func fetch(_ done: @escaping (FetchOutcome) -> Void) {
        ensureReady { ok in
            guard ok else { orbLog("fetch: page not ready"); done(.failed("network")); return }
            self.webView.callAsyncJavaScript(self.site.usageJS, arguments: [:], in: nil, in: .page) { result in
                switch result {
                case .success(let value):
                    guard let s = value as? String, let d = s.data(using: .utf8),
                          let obj = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] else {
                        orbLog("fetch: unparsable result"); done(.failed("parse")); return
                    }
                    if let data = obj["data"] as? [String: Any] {
                        orbLog("\(self.site.name) fetch ok")
                        done(.ok(data)); return
                    }
                    orbLog("fetch error: \(s)")
                    let status = (obj["status"] as? NSNumber)?.intValue ?? 0
                    if status == 401 || status == 403 { done(.needLogin) }
                    else { done(.failed((obj["error"] as? String) ?? "unknown")) }
                case .failure(let e):
                    orbLog("fetch js failure: \(e.localizedDescription)")
                    self.ready = false
                    done(.failed(e.localizedDescription))
                }
            }
        }
    }

    static let sessionsScript = """
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
      const tracked = new Set(trackedIds || []);
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
        out.push({ id: c.uuid, kind: 'chat', title: c.name || '', live: live, req: req,
                   startedMs: ms(c.live_status_started_at), settledMs: ms(c.last_settled_at), updatedMs: ms(c.updated_at),
                   url: '/chat/' + c.uuid });
      }
      // Cloud Claude Code sessions (claude.ai/code). Skip ones that back a chat above.
      try {
        const linked = new Set([...byId.values()].map(c => c.workspace_session_id).filter(Boolean));
        const H = { 'anthropic-version': '2023-06-01' };
        const r = await fetch('/v1/code/sessions?exclude_tags=-&include_trigger_sessions=true&limit=40', { credentials: 'include', headers: H });
        if (r.ok) {
          const d = (await r.json()).data || [];
          for (const s of d) {
            if (!s || !s.id || linked.has(s.id) || s.title === '__warming__') continue;
            if ((s.tags || []).some(t => t.startsWith('bard-conversation:'))) continue;
            const worker = (s.worker_status || '').toLowerCase(), bucket = (s.status_bucket || '').toLowerCase();
            const busy = (worker && worker !== 'idle') || bucket === 'working';
            if (!busy && !tracked.has(s.id)) continue;
            let x = s, req = 0;
            try { const rr = await fetch('/v1/code/sessions/' + s.id, { credentials: 'include', headers: H }); if (rr.ok) { const dd = await rr.json(); x = dd.response_shape || dd; } } catch (e) {}
            req = (x.requires_action_details_list || []).length;
            const live = busy ? (req > 0 || bucket === 'blocked' ? 'permission' : 'running') : '';
            let url = x.session_url || s.session_url || '';
            try { if (url) { const u = new URL(url); url = u.pathname + u.search; } } catch (e) {}
            if (!url) url = '/code/' + s.id.replace(/^cse_/, 'session_');
            out.push({ id: s.id, kind: 'code-cloud', title: x.title || s.title || 'Claude Code', live, req,
                       startedMs: 0, settledMs: ms(x.last_event_at || s.last_event_at), updatedMs: ms(x.updated_at || s.updated_at), url });
          }
        }
      } catch (e) {}
      return JSON.stringify({ sessions: out });
    } catch (e) {
      return JSON.stringify({ error: String(e) });
    }
    """

    /// Chats that are working now, plus the ones the orb is already tracking.
    func fetchSessions(tracked: [String], _ done: @escaping ([[String: Any]]?) -> Void) {
        ensureReady { ok in
            guard ok else { done(nil); return }
            self.webView.callAsyncJavaScript(Self.sessionsScript, arguments: ["trackedIds": tracked], in: nil, in: .page) { result in
                switch result {
                case .failure(let e): orbLog("sessions js failure: \(e)"); done(nil)
                case .success(let v):
                    guard let s = v as? String, let d = s.data(using: .utf8),
                          let obj = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] else { orbLog("sessions: unparsable \(String(describing: v))"); done(nil); return }
                    if let e = obj["error"] { orbLog("sessions error: \(e)"); done(nil); return }
                    let list = obj["sessions"] as? [[String: Any]] ?? []
                    done(list)
                }
            }
        }
    }

    // MARK: sign-in window

    func showLogin() {
        if let w = loginWindow {
            NSApp.activate(ignoringOtherApps: true)
            w.makeKeyAndOrderFront(nil)
            return
        }
        orbLog("opening sign-in window")
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 744),
                         styleMask: [.titled, .closable, .resizable, .miniaturizable],
                         backing: .buffered, defer: false)
        w.title = "Sign in to \(site.name) (used only to read usage)"
        w.isReleasedWhenClosed = false
        w.delegate = self
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 480, height: 744))
        let bar = NSView(frame: NSRect(x: 0, y: 0, width: 480, height: 44))
        bar.autoresizingMask = [.width]
        let label = NSTextField(labelWithString: "Sign in — this window closes by itself.")
        label.frame = NSRect(x: 12, y: 13, width: 290, height: 18)
        label.autoresizingMask = [.width]
        label.font = .systemFont(ofSize: 12)
        label.textColor = .secondaryLabelColor
        label.lineBreakMode = .byTruncatingTail
        let reload = NSButton(title: "Reload", target: self, action: #selector(reloadLogin))
        reload.bezelStyle = .rounded
        reload.frame = NSRect(x: 310, y: 8, width: 78, height: 28)
        reload.autoresizingMask = [.minXMargin]
        let done = NSButton(title: "Done", target: self, action: #selector(doneLogin))
        done.bezelStyle = .rounded
        done.frame = NSRect(x: 392, y: 8, width: 78, height: 28)
        done.autoresizingMask = [.minXMargin]
        bar.addSubview(label); bar.addSubview(reload); bar.addSubview(done)

        webView.removeFromSuperview()
        webView.frame = NSRect(x: 0, y: 44, width: 480, height: 700)
        webView.autoresizingMask = [.width, .height]
        content.addSubview(webView)
        content.addSubview(bar)
        w.contentView = content
        w.center()
        loginWindow = w
        statusLabel = label
        closingLogin = false
        ready = false
        loading = false
        webView.load(URLRequest(url: URL(string: site.loginURL)!))
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
        pollTimer = Timer.scheduledTimer(withTimeInterval: 2.5, repeats: true) { [weak self] _ in self?.checkSignedIn() }
    }

    @objc private func reloadLogin() { webView.reload() }
    @objc private func doneLogin() { loginWindow?.close() }

    private func checkSignedIn() {
        guard loginWindow != nil, !closingLogin, onClaude else { return }
        webView.callAsyncJavaScript(site.checkJS, arguments: [:], in: nil, in: .page) { [weak self] res in
            guard let self = self, self.loginWindow != nil, !self.closingLogin else { return }
            var s = "?"
            switch res {
            case .success(let v): s = (v as? String) ?? "?"
            case .failure(let e): s = "js failure: \(e.localizedDescription)"
            }
            orbLog("sign-in check at \(self.webView.url?.path ?? "-"): \(s)")
            if s == "ok" {
                self.closingLogin = true
                self.statusLabel?.stringValue = "Signed in ✓ — reading usage…"
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { self.loginWindow?.close() }
            } else {
                self.statusLabel?.stringValue = "Not signed in yet (\(s))"
            }
        }
    }

    // Sign-in providers (e.g. Google) open a popup that reports back to this page,
    // so it must be a real child web view that keeps its link to the opener.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        orbLog("popup → \(navigationAction.request.url?.host ?? "-")")
        let pv = WKWebView(frame: NSRect(x: 0, y: 0, width: 500, height: 640), configuration: configuration)
        pv.customUserAgent = safariUA
        pv.uiDelegate = self
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 640),
                         styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        w.title = "Sign in"
        w.isReleasedWhenClosed = false
        w.contentView = pv
        w.delegate = self
        if let p = loginWindow?.frame {
            w.setFrameOrigin(NSPoint(x: p.midX - 220, y: p.midY - 360))
        } else {
            w.center()
        }
        popups.append((pv, w))
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
        return pv
    }

    func webViewDidClose(_ webView: WKWebView) {
        if let i = popups.firstIndex(where: { $0.0 === webView }) {
            let w = popups[i].1
            popups.remove(at: i)
            w.close()
            orbLog("popup closed by page")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { self.checkSignedIn() }
        }
    }

    func windowWillClose(_ notification: Notification) {
        guard let w = notification.object as? NSWindow else { return }
        if let i = popups.firstIndex(where: { $0.1 === w }) { popups.remove(at: i); return }
        guard w === loginWindow else { return }
        orbLog("sign-in window closed")
        pollTimer?.invalidate()
        pollTimer = nil
        for (_, pw) in popups { pw.close() }
        popups.removeAll()
        loginWindow = nil
        statusLabel = nil
        webView.removeFromSuperview()
        webView.frame = NSRect(x: 0, y: 0, width: 480, height: 700)
        hostWindow.contentView = webView
        ready = false
        loading = false
        onLoginFinished?()
    }
}

// MARK: - Usage source 2 (fallback): Claude Code's login, if it is installed

enum ClaudeCodeUsage {
    static func credentialsJSON() -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        p.arguments = ["find-generic-password", "-s", "Claude Code-credentials", "-w"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        do {
            try p.run()
            let data = out.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            if p.terminationStatus == 0, let s = String(data: data, encoding: .utf8), !s.isEmpty { return s }
        } catch {}
        let file = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/.credentials.json")
        return try? String(contentsOf: file, encoding: .utf8)
    }

    static func token() -> String? {
        guard let raw = credentialsJSON(), let d = raw.trimmingCharacters(in: .whitespacesAndNewlines).data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any],
              let oauth = obj["claudeAiOauth"] as? [String: Any],
              let tok = oauth["accessToken"] as? String else { return nil }
        if let exp = (oauth["expiresAt"] as? NSNumber)?.doubleValue, exp > 0, exp / 1000 < Date().timeIntervalSince1970 {
            return nil
        }
        return tok
    }

    static func fetch(_ done: @escaping ([String: Any]?) -> Void) {
        DispatchQueue.global(qos: .utility).async {
            guard let tok = token() else { DispatchQueue.main.async { done(nil) }; return }
            var req = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
            req.setValue("Bearer \(tok)", forHTTPHeaderField: "Authorization")
            req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
            req.setValue("application/json", forHTTPHeaderField: "Accept")
            req.timeoutInterval = 15
            URLSession.shared.dataTask(with: req) { data, resp, _ in
                var out: [String: Any]? = nil
                if let http = resp as? HTTPURLResponse, http.statusCode == 200, let d = data,
                   let j = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any],
                   j["five_hour"] != nil || j["seven_day"] != nil {
                    out = j
                }
                DispatchQueue.main.async { done(out) }
            }.resume()
        }
    }
}

// MARK: - Usage source 3: Codex app-server

/// Use Codex's authenticated RPC interface; never substitute historical logs for live limits.
enum CodexUsage {
    struct Result {
        var data: [String: Any]
        var stale: Bool
        var source: String
    }

    static var executable: URL? {
        let paths = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
        let candidates = (paths + ["/opt/homebrew/bin", "/usr/local/bin",
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin").path])
            .map { URL(fileURLWithPath: $0).appendingPathComponent("codex") }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }
    static var isInstalled: Bool { executable != nil }

    static func normaliseResponse(_ response: [String: Any]) -> [String: Any]? {
        let limits: [String: Any]
        if let buckets = response["rateLimitsByLimitId"] as? [String: Any] {
            // A model-specific bucket must not masquerade as the overall Codex allowance.
            guard let codex = buckets["codex"] as? [String: Any] else { return [:] }
            limits = codex
        } else if let legacy = response["rateLimits"] as? [String: Any] {
            limits = legacy
        } else { return nil }
        var out: [String: Any] = [:]
        for name in ["primary", "secondary"] {
            guard let w = limits[name] as? [String: Any],
                  let used = w["usedPercent"] as? NSNumber,
                  let minutes = w["windowDurationMins"] as? NSNumber,
                  used.doubleValue.isFinite else { continue }
            // Do not invent a 5-hour window when the account only reports a weekly limit.
            let key: String
            switch minutes.doubleValue {
            case 300: key = "five_hour"
            case 10080: key = "seven_day"
            default: continue
            }
            var value: [String: Any] = ["utilization": max(0, min(100, used.doubleValue))]
            if let reset = w["resetsAt"] as? NSNumber, reset.doubleValue.isFinite {
                value["resets_at"] = ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: reset.doubleValue))
            }
            out[key] = value
        }
        return out
    }

    /// One short-lived stdio connection per refresh. poll bounds both handshake and RPC reads.
    static func read(timeout: TimeInterval = 20) -> Result? {
        guard let binary = executable else { orbLog("codex: CLI not found"); return nil }
        let process = Process(), input = Pipe(), output = Pipe()
        process.executableURL = binary
        process.arguments = ["app-server"]
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { orbLog("codex: app-server could not start"); return nil }
        defer {
            try? input.fileHandleForWriting.close()
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            process.waitUntilExit()
            try? output.fileHandleForReading.close()
        }
        let deadline = Date().addingTimeInterval(timeout)
        var buffer = Data()
        func send(_ message: [String: Any]) throws {
            var data = try JSONSerialization.data(withJSONObject: message)
            data.append(10)
            try input.fileHandleForWriting.write(contentsOf: data)
        }
        func receive(id: Int) -> [String: Any]? {
            while Date() < deadline {
                while let end = buffer.firstIndex(of: 10) {
                    let line = buffer.prefix(upTo: end)
                    let obj = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any]
                    buffer.removeSubrange(...end)
                    if let obj = obj, (obj["id"] as? Int) == id { return obj }
                }
                var descriptor = pollfd(fd: output.fileHandleForReading.fileDescriptor, events: Int16(POLLIN), revents: 0)
                let remaining = Int32(max(1, deadline.timeIntervalSinceNow * 1000))
                let ready = poll(&descriptor, 1, remaining)
                if ready < 0 && errno == EINTR { continue }
                guard ready > 0 else { return nil }
                let chunk = output.fileHandleForReading.availableData
                guard !chunk.isEmpty else { return nil }
                buffer.append(chunk)
                guard buffer.count < 4 * 1024 * 1024 else { return nil }
            }
            return nil
        }
        do {
            try send(["id": 0, "method": "initialize", "params": ["clientInfo": [
                "name": "claude_usage_orb", "title": "Claude Usage Orb", "version": "1.0"]]])
            guard let hello = receive(id: 0), hello["result"] != nil else {
                orbLog("codex: app-server initialization failed or timed out"); return nil
            }
            try send(["method": "initialized", "params": [:]])
            try send(["id": 1, "method": "account/rateLimits/read"])
            guard let reply = receive(id: 1), let result = reply["result"] as? [String: Any],
                  let data = normaliseResponse(result) else {
                orbLog("codex: rate limits unavailable; check codex login status"); return nil
            }
            return Result(data: data, stale: false, source: "Codex app-server")
        } catch { orbLog("codex: app-server connection closed"); return nil }
    }

    static func fetch(_ done: @escaping (Result?) -> Void) {
        DispatchQueue.global(qos: .utility).async {
            let result = read()
            DispatchQueue.main.async { done(result) }
        }
    }
}

// MARK: - Chat activity tracking

let kTasksKey = "ClaudeUsageOrbTasks"
let taskPollEvery: TimeInterval = 6

struct OrbTask: Codable {
    var id: String
    var title: String
    var url: String
    var state: String          // running | permission | done
    var bucket: String
    var startedAt: Double      // ms since 1970
    var endedAt: Double?
    var idleSeen: Int
    var kind: String?          // chat | code-cloud | code-local | codex-local | codex-desktop
    var cwd: String?
    /// Sessions tracked through a local hook file rather than claude.ai.
    var isLocal: Bool { kind == "code-local" || kind == "codex-local" }
}

/// Terminal sessions written by hooks/claude-monitor-hook.py — Claude Code into
/// `code-sessions/`, Codex CLI into `codex-sessions/`. Same file format, different `kind`.
enum LocalCodeSessions {
    static var support: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/ClaudeMonitor")
    }
    static let folders: [(dir: String, kind: String, title: String)] = [
        ("code-sessions", "code-local", "Claude Code"),
        ("codex-sessions", "codex-local", "Codex"),
    ]
    static func dir(for kind: String) -> URL {
        support.appendingPathComponent(folders.first(where: { $0.kind == kind })?.dir ?? "code-sessions")
    }
    static func read() -> [[String: Any]] {
        var out: [[String: Any]] = []
        for f in folders { out += read(dir: support.appendingPathComponent(f.dir), kind: f.kind, fallbackTitle: f.title) }
        return out
    }
    private static func read(dir: URL, kind: String, fallbackTitle: String) -> [[String: Any]] {
        guard let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return [] }
        var out: [[String: Any]] = []
        let now = Date().timeIntervalSince1970 * 1000
        for f in files where f.pathExtension == "json" {
            guard let d = try? Data(contentsOf: f), var o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any],
                  let id = o["id"] as? String else { continue }
            var state = (o["state"] as? String) ?? ""
            let updated = (o["updatedAt"] as? NSNumber)?.doubleValue ?? 0
            // If the claude process is gone (terminal closed without SessionEnd), a running card would stick forever.
            if state != "done", let pid = (o["pid"] as? NSNumber)?.int32Value, pid > 0, kill(pid, 0) != 0, errno == ESRCH {
                if now - updated > 15_000 { try? FileManager.default.removeItem(at: f); continue }
            }
            if state.isEmpty { continue }
            if state != "done" && now - updated > 6 * 3600_000 { state = "done"; o["endedAt"] = updated }
            out.append(["id": id, "kind": kind, "title": (o["title"] as? String) ?? fallbackTitle,
                        "live": state, "req": state == "permission" ? 1 : 0,
                        "startedMs": (o["startedAt"] as? NSNumber)?.doubleValue ?? updated,
                        "settledMs": (o["endedAt"] as? NSNumber)?.doubleValue ?? 0,
                        "url": "", "cwd": (o["cwd"] as? String) ?? ""])
        }
        return out
    }
    static func remove(_ id: String, kind: String?) {
        try? FileManager.default.removeItem(at: dir(for: kind ?? "code-local").appendingPathComponent(id + ".json"))
    }
}

// MARK: - Codex desktop activity (read-only local records)

final class CodexDesktopSessions {
    struct Activity {
        var state = ""
        var turnID = ""
        var started: Double = 0
        var ended: Double = 0
        mutating func apply(_ record: [String: Any]) {
            guard record["type"] as? String == "event_msg",
                  let event = record["payload"] as? [String: Any],
                  let type = event["type"] as? String else { return }
            let timestamp = CodexDesktopSessions.milliseconds(record["timestamp"])
            let turn = event["turn_id"] as? String ?? ""
            switch type {
            case "task_started":
                if !turn.isEmpty && turn == turnID { return }
                turnID = turn
                state = "running"
                started = CodexDesktopSessions.milliseconds(event["started_at"]) ?? timestamp ?? 0
                ended = 0
            case "task_complete", "turn_aborted":
                guard turnID.isEmpty || turn.isEmpty || turnID == turn else { return }
                state = "done"
                ended = CodexDesktopSessions.milliseconds(event["completed_at"]) ?? timestamp ?? 0
            default: break
            }
        }
    }
    struct Cursor {
        var offset: UInt64 = 0
        var pending = Data()
        var activity = Activity()
        var fileID: UInt64 = 0
    }
    private var cursors: [String: Cursor] = [:]
    let home: URL
    let hooks: URL
    init(home: URL = URL(fileURLWithPath: ProcessInfo.processInfo.environment["CODEX_HOME"] ??
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex").path),
         hooks: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/ClaudeMonitor/codex-sessions")) {
        self.home = home
        self.hooks = hooks
    }
    static func displayState(activity: Activity, hook: [String: Any]?) -> String {
        // Completion from the transcript wins; old turns must never add an Allow button.
        guard activity.state == "running", !activity.turnID.isEmpty,
              let hook = hook, hook["turnId"] as? String == activity.turnID,
              let updated = hook["updatedAt"] as? NSNumber, updated.doubleValue >= activity.started,
              hook["state"] as? String == "permission",
              let pending = hook["pendingApprovals"] as? [String: Any], !pending.isEmpty else { return activity.state }
        return "permission"
    }
    /// Only user-facing conversations may create cards. Background suggestion jobs may
    /// emit identical hooks but have no interactive thread entry in Codex's index.
    func foregroundIDs() -> Set<String>? {
        guard let files = try? FileManager.default.contentsOfDirectory(at: home, includingPropertiesForKeys: nil),
              let database = files.filter({ $0.lastPathComponent.hasPrefix("state_") && $0.pathExtension == "sqlite" })
                .sorted(by: { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedDescending }).first else { return nil }
        var db: OpaquePointer?
        guard sqlite3_open_v2(database.path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK else {
            if let db = db { sqlite3_close(db) }; return nil
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 100)
        var query: OpaquePointer?
        let sql = "SELECT id FROM threads WHERE archived=0 AND source IN ('cli','vscode','appServer') AND (thread_source IS NULL OR thread_source IN ('user','agent_created_thread'))"
        guard sqlite3_prepare_v2(db, sql, -1, &query, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(query) }
        var ids = Set<String>()
        var status = sqlite3_step(query)
        while status == SQLITE_ROW {
            if let value = sqlite3_column_text(query, 0) { ids.insert(String(cString: value)) }
            status = sqlite3_step(query)
        }
        return status == SQLITE_DONE ? ids : nil
    }
    static func milliseconds(_ value: Any?) -> Double? {
        if let n = value as? NSNumber { return n.doubleValue > 1e12 ? n.doubleValue : n.doubleValue * 1000 }
        guard let text = value as? String else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let date = formatter.date(from: text) ?? ISO8601DateFormatter().date(from: text)
        return date.map { $0.timeIntervalSince1970 * 1000 }
    }
    /// Cache byte offsets so repeated polls read only appended data, including split JSON lines.
    func activity(at path: String) -> Activity? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let size = attrs[.size] as? NSNumber,
              let file = try? FileHandle(forReadingFrom: URL(fileURLWithPath: path)) else { return nil }
        defer { try? file.close() }
        let identity = (attrs[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
        var cursor = cursors[path] ?? Cursor()
        if cursor.offset > size.uint64Value || cursor.fileID != identity { cursor = Cursor() }
        cursor.fileID = identity
        do {
            try file.seek(toOffset: cursor.offset)
            // Bound work per poll; large histories are caught up incrementally off the UI thread.
            let limit = min(size.uint64Value, cursor.offset + 32 * 1024 * 1024)
            while cursor.offset < limit {
                guard let chunk = try file.read(upToCount: Int(min(262144, limit - cursor.offset))), !chunk.isEmpty else { break }
                cursor.offset += UInt64(chunk.count)
                cursor.pending.append(chunk)
                while let end = cursor.pending.firstIndex(of: 10) {
                    let line = cursor.pending.prefix(upTo: end)
                    if let record = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] {
                        cursor.activity.apply(record)
                    }
                    cursor.pending.removeSubrange(...end)
                }
            }
            cursors[path] = cursor
            // Never display an old start while we are still catching up to a later completion.
            return cursor.offset >= size.uint64Value ? cursor.activity : nil
        } catch { return nil }
    }
    func read(tracked: Set<String>, now: Date = Date()) -> [[String: Any]] {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: home, includingPropertiesForKeys: nil),
              let database = files.filter({ $0.lastPathComponent.hasPrefix("state_") && $0.pathExtension == "sqlite" })
                .sorted(by: { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedDescending }).first else { return [] }
        var db: OpaquePointer?
        guard sqlite3_open_v2(database.path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK else {
            if let db = db { sqlite3_close(db) }; return []
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 100)
        var statement: OpaquePointer?
        // Desktop currently persists source=vscode, originator=Codex Desktop. Exclude subagents and CLI.
        let sql = "SELECT id, COALESCE(name, title), rollout_path, cwd, updated_at FROM threads WHERE archived=0 AND originator='Codex Desktop' AND source IN ('vscode','appServer') AND (thread_source IS NULL OR thread_source IN ('user','agent_created_thread')) ORDER BY updated_at DESC"
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(statement) }
        func text(_ column: Int32) -> String {
            sqlite3_column_text(statement, column).map { String(cString: $0) } ?? ""
        }
        var result: [[String: Any]] = []
        var retained = Set<String>()
        while sqlite3_step(statement) == SQLITE_ROW {
            let id = text(0), path = text(2)
            guard UUID(uuidString: id) != nil else { continue }
            let updated = sqlite3_column_double(statement, 4)
            guard tracked.contains(id) || now.timeIntervalSince1970 - updated < 2 * 86400 else { continue }
            retained.insert(path)
            guard let activity = activity(at: path), !activity.state.isEmpty else { continue }
            // Ignore abandoned old starts on first discovery; don't fabricate a completion event.
            if activity.state == "running" && !tracked.contains(id) && now.timeIntervalSince1970 - updated > 6 * 3600 { continue }
            let hookData = try? Data(contentsOf: hooks.appendingPathComponent(id + ".json"))
            let hook = hookData.flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] }
            let state = Self.displayState(activity: activity, hook: hook?["id"] as? String == id ? hook : nil)
            result.append(["id": id, "kind": "codex-desktop", "title": text(1), "cwd": text(3),
                "live": state, "req": state == "permission" ? 1 : 0, "startedMs": activity.started, "settledMs": activity.ended,
                "url": "codex://threads/" + id])
        }
        cursors = cursors.filter { retained.contains($0.key) }
        return result
    }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    var orb: OrbWindowController!
    let web = WebSession(site: .claude)
    var statusItem: NSStatusItem!
    var timer: Timer?
    var refreshing = false
    var promptedLogin = false
    var lastSession: Double?
    var lastWeek: Double?
    var source = ""
    var lastOK: Date?
    var tasks: [OrbTask] = []
    var taskTimer: Timer?
    var polling = false
    var localPolling = false
    let desktopSessions = CodexDesktopSessions()

    // Codex (right half of the orb). `codexPayload` is what the page gets under `codex`:
    // a dict when Codex is shown, NSNull when it is off or not installed.
    var codexPayload: Any = NSNull()
    var lastCodexSession: Double?
    var lastCodexWeek: Double?
    var codexSource = ""
    var codexFetching = false
    var lastClaudePayload: [String: Any]?
    var codexLoginProcess: Process?
    var codexWanted: Bool { orb.style == "dual" }

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMainMenu()
        orbLog("app started")
        web.onLoginFinished = { [weak self] in self?.refresh() }
        let s = UserDefaults.standard.double(forKey: kScaleKey)
        orb = OrbWindowController(scale: s > 0 ? min(maxScale, max(minScale, CGFloat(s))) : 1.0)
        orb.overlay.onDoubleClick = { [weak self] in self?.doubleClicked() }
        orb.overlay.onResize = { [weak self] f in self?.resize(by: f) }
        orb.overlay.onCardClick = { [weak self] p in
            guard let self = self else { return }
            self.orb.cardAction(at: p) { id, action in self.cardAction(id: id, action: action) }
        }
        orb.overlay.onRightClick = { [weak self] e in
            guard let self = self else { return }
            NSMenu.popUpContextMenu(self.makeMenu(), with: e, for: self.orb.overlay)
        }
        if !UserDefaults.standard.bool(forKey: kHiddenKey) { orb.show() }

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        updateStatusIcon()
        let m = NSMenu()
        m.delegate = self
        statusItem.menu = m

        pushUsage()
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: refreshEvery, repeats: true) { [weak self] _ in self?.refresh() }
        loadTasks()
        pushTasks()
        taskTimer = Timer.scheduledTimer(withTimeInterval: taskPollEvery, repeats: true) { [weak self] _ in self?.pollTasks() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.pollTasks() }
        let nc = NSWorkspace.shared.notificationCenter
        nc.addObserver(self, selector: #selector(didWake), name: NSWorkspace.didWakeNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(screensChanged),
                                               name: NSApplication.didChangeScreenParametersNotification, object: nil)
    }

    @objc func didWake() {
        web.invalidate()
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in self?.refresh() }
    }
    @objc func screensChanged() { orb.ensureOnScreen() }

    // MARK: data

    @objc func refresh() {
        refreshCodex()
        if refreshing || web.isLoginOpen { return }
        refreshing = true
        web.fetch { [weak self] outcome in
            guard let self = self else { return }
            switch outcome {
            case .ok(let d):
                self.refreshing = false
                self.deliver(d, source: "claude.ai")
            case .needLogin, .failed:
                var needLogin = false
                if case .needLogin = outcome { needLogin = true }
                ClaudeCodeUsage.fetch { d in
                    self.refreshing = false
                    if let d = d { self.deliver(d, source: "Claude Code"); return }
                    if needLogin {
                        self.sendUsage(["status": "login"])
                        if !self.promptedLogin { self.promptedLogin = true; self.openLogin() }
                    } else {
                        self.sendUsage(["status": "error"])
                    }
                }
            }
        }
    }

    /// Codex runs on its own, in parallel with the claude.ai read; whichever finishes later re-sends the combined payload.
    func refreshCodex() {
        guard codexWanted else {
            if !(codexPayload is NSNull) { codexPayload = NSNull(); lastCodexSession = nil; lastCodexWeek = nil; pushUsage() }
            return
        }
        guard !codexFetching else { return }
        codexFetching = true
        CodexUsage.fetch { [weak self] r in self?.gotCodex(r) }
    }

    func gotCodex(_ r: CodexUsage.Result?) {
        self.codexFetching = false
        guard codexWanted else { return }
        guard let r = r else {
            // A failed refresh is unavailable, not zero or a historical percentage.
            self.codexPayload = ["session": NSNull(), "week": NSNull(), "stale": true]
            self.lastCodexSession = nil
            self.lastCodexWeek = nil
            self.codexSource = "Unavailable — sign in with Codex or retry"
            self.pushUsage()
            return
        }
        self.codexPayload = ["session": Self.win(r.data, "five_hour"), "week": Self.win(r.data, "seven_day"), "stale": r.stale]
        self.lastCodexSession = Self.pct(r.data, "five_hour")
        self.lastCodexWeek = Self.pct(r.data, "seven_day")
        self.codexSource = r.source
        orbLog("codex ok (\(r.source)): five_hour=\(self.lastCodexSession ?? -1) seven_day=\(self.lastCodexWeek ?? -1)")
        self.pushUsage()
    }

    static func win(_ d: [String: Any], _ key: String) -> Any {
        guard let w = d[key] as? [String: Any] else { return NSNull() }
        return ["pct": w["utilization"] ?? NSNull(), "resetsAt": w["resets_at"] ?? NSNull()]
    }
    static func pct(_ d: [String: Any], _ key: String) -> Double? { ((d[key] as? [String: Any])?["utilization"] as? NSNumber)?.doubleValue }

    func deliver(_ d: [String: Any], source: String) {
        lastSession = Self.pct(d, "five_hour") ?? 0
        lastWeek = Self.pct(d, "seven_day") ?? 0
        self.source = source
        lastOK = Date()
        sendUsage(["status": "ok", "session": Self.win(d, "five_hour"), "week": Self.win(d, "seven_day")])
    }

    /// Sends the Claude payload plus whatever Codex state we have, and sizes the window for it.
    func sendUsage(_ claude: [String: Any]) {
        lastClaudePayload = claude
        pushUsage()
    }
    func pushUsage() {
        var p = lastClaudePayload ?? ["status": "loading"]
        p["codex"] = codexWanted ? codexPayload : NSNull()
        orb.setQuad(codexWanted)
        orb.send(p)
    }

    // MARK: chat activity

    func loadTasks() {
        if let d = UserDefaults.standard.data(forKey: kTasksKey),
           let t = try? JSONDecoder().decode([OrbTask].self, from: d) { tasks = t }
        if let ids = desktopSessions.foregroundIDs() { removeBackgroundCards(foregroundIDs: ids) }
    }
    func removeBackgroundCards(foregroundIDs: Set<String>) {
        let count = tasks.count
        tasks.removeAll { ($0.kind == "codex-local" || $0.kind == "codex-desktop") && !foregroundIDs.contains($0.id) }
        if tasks.count != count { saveTasks(); pushTasks() }
    }
    func saveTasks() {
        if let d = try? JSONEncoder().encode(tasks) { UserDefaults.standard.set(d, forKey: kTasksKey) }
    }
    func pushTasks() {
        orb.setTasks(tasks.map { t in
            var o: [String: Any] = ["id": t.id, "title": t.title, "state": t.state, "bucket": t.bucket, "startedAt": t.startedAt, "kind": t.kind ?? "chat"]
            if let e = t.endedAt { o["endedAt"] = e }
            return o
        })
    }

    func pollTasks() {
        // Local sessions must continue polling even when Claude is signed out or offline.
        if !localPolling {
            localPolling = true
            let tracked = Set(tasks.filter { $0.kind == "codex-desktop" }.map { $0.id })
            DispatchQueue.global(qos: .utility).async { [weak self] in
                guard let self = self else { return }
                let foreground = self.desktopSessions.foregroundIDs()
                let desktop = self.desktopSessions.read(tracked: tracked).filter {
                    foreground?.contains($0["id"] as? String ?? "") == true
                }
                let desktopIDs = Set(desktop.compactMap { $0["id"] as? String })
                let local = LocalCodeSessions.read().filter {
                    let id = $0["id"] as? String ?? ""
                    return !desktopIDs.contains(id) && ($0["kind"] as? String != "codex-local" || foreground?.contains(id) == true)
                }
                DispatchQueue.main.async {
                    self.localPolling = false
                    if let foreground = foreground { self.removeBackgroundCards(foregroundIDs: foreground) }
                    self.ingest(desktop + local)
                }
            }
        }
        guard !polling, !web.isLoginOpen, lastOK != nil else { return }
        polling = true
        let tracked = tasks.filter { !$0.isLocal && $0.kind != "codex-desktop" && $0.state != "done" }.map { $0.id }
        web.fetchSessions(tracked: tracked) { [weak self] list in
            guard let self = self else { return }
            self.polling = false
            self.ingest(list ?? [])
        }
    }

    func ingest(_ list: [[String: Any]]) {
        let now = Date().timeIntervalSince1970 * 1000
        var changed = false
        for s in list {
            guard let id = s["id"] as? String else { continue }
            let live = (s["live"] as? String ?? "").lowercased()
            let req = (s["req"] as? NSNumber)?.intValue ?? 0
            var title = (s["title"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if title.isEmpty { title = "Untitled chat" }
            let url = s["url"] as? String ?? ""
            let startedMs = (s["startedMs"] as? NSNumber)?.doubleValue ?? 0
            let settledMs = (s["settledMs"] as? NSNumber)?.doubleValue ?? 0
            let kind = s["kind"] as? String ?? "chat"
            let cwd = s["cwd"] as? String
            let busy = !live.isEmpty && !["done", "idle", "completed", "settled", "finished", "stopped", "none"].contains(live)
            let perm = req > 0 || live.contains("permission") || live.contains("approv") || live.contains("action") || live.contains("input") || live.contains("wait")
            if let i = tasks.firstIndex(where: { $0.id == id }) {
                var t = tasks[i]
                let before = (t.state, t.title, t.bucket)
                let previousStart = t.startedAt
                if busy {
                    if t.state == "done" { t.startedAt = startedMs > 0 ? startedMs : now; t.endedAt = nil }
                    else if startedMs > 0 && (kind == "codex-desktop" ? startedMs != t.startedAt : abs(startedMs - t.startedAt) > 60_000) { t.startedAt = startedMs }
                    t.state = perm ? "permission" : "running"
                    t.idleSeen = 0
                } else if t.state != "done" {
                    t.idleSeen += 1
                    if t.idleSeen >= 2 || kind == "code-local" || kind == "codex-local" || kind == "codex-desktop" {
                        t.state = "done"
                        t.endedAt = settledMs > t.startedAt ? settledMs : now
                    }
                }
                t.title = title
                t.bucket = live
                t.kind = kind
                if let c = cwd { t.cwd = c }
                if !url.isEmpty { t.url = url }
                if before != (t.state, t.title, t.bucket) || previousStart != t.startedAt { changed = true; orbLog("chat '\(title)' → \(t.state) (\(live))") }
                tasks[i] = t
            } else if busy {
                tasks.append(OrbTask(id: id, title: title, url: url, state: perm ? "permission" : "running",
                                     bucket: live, startedAt: startedMs > 0 ? startedMs : now, endedAt: nil, idleSeen: 0,
                                     kind: kind, cwd: cwd))
                changed = true
                orbLog("chat '\(title)' started (\(live), req=\(req))")
            }
        }
        if changed { saveTasks(); pushTasks() }
    }

    func cardAction(id: String, action: String) {
        guard let t = tasks.first(where: { $0.id == id }) else { return }
        orbLog("card click kind=\(t.kind ?? "chat") action=\(action) id=\(id)")
        openChat(t) { [weak self] opened in
            guard let self = self else { return }
            guard opened else {
                orbLog("card navigation failed; retaining card \(id)")
                let alert = NSAlert()
                alert.messageText = "Could not open the chat"
                alert.informativeText = "The task card has been kept. Open the app and try again."
                alert.runModal()
                return
            }
            // Opening is asynchronous: don't remove a task that started another turn meanwhile.
            if action == "check", let index = self.tasks.firstIndex(where: { $0.id == id }),
               self.tasks[index].state == "done", self.tasks[index].startedAt == t.startedAt {
                if t.isLocal { LocalCodeSessions.remove(t.id, kind: t.kind) }
                self.tasks.remove(at: index)
                self.saveTasks()
                self.pushTasks()
            }
        }
    }

    func openChat(_ t: OrbTask, completion: @escaping (Bool) -> Void) {
        let ws = NSWorkspace.shared
        if t.kind == "codex-desktop" {
            guard UUID(uuidString: t.id) != nil,
                  let url = URL(string: "codex://threads/" + t.id + "?hostId=local"),
                  let application = ws.urlForApplication(withBundleIdentifier: "com.openai.codex") else {
                completion(false); return
            }
            // The current desktop app may be named ChatGPT. Resolve by bundle ID, not display name.
            let config = NSWorkspace.OpenConfiguration()
            config.activates = true
            ws.open([url], withApplicationAt: application, configuration: config) { app, error in
                DispatchQueue.main.async {
                    let opened = app != nil && error == nil
                    if opened { app?.activate(options: []) }
                    orbLog("Codex navigation delivery=\(opened) thread=\(t.id) error=\(error?.localizedDescription ?? "none")")
                    completion(opened)
                }
            }
            return
        }
        if t.isLocal {
            let terminals = ["com.googlecode.iterm2", "com.apple.Terminal", "dev.warp.Warp-Stable", "com.mitchellh.ghostty", "net.kovidgoyal.kitty", "com.microsoft.VSCode", "com.todesktop.230313mzl4w4u92"]
            if let app = ws.runningApplications.first(where: { terminals.contains($0.bundleIdentifier ?? "") }) {
                completion(app.activate(options: []))
            } else { completion(false) }
            return
        }
        let path = t.url.isEmpty ? "/chat/" + t.id : t.url
        if let deep = URL(string: "claude://claude.ai" + path), ws.urlForApplication(toOpen: deep) != nil,
           ws.open(deep) { completion(true); return }
        if let application = ws.urlForApplication(withBundleIdentifier: "com.anthropic.claudefordesktop") {
            let config = NSWorkspace.OpenConfiguration()
            config.activates = true
            ws.openApplication(at: application, configuration: config) { app, error in
                DispatchQueue.main.async { completion(app != nil && error == nil) }
            }
            return
        }
        completion(URL(string: "https://claude.ai" + path).map { ws.open($0) } ?? false)
    }

    @objc func clearFinished() {
        for t in tasks where t.state == "done" && t.isLocal { LocalCodeSessions.remove(t.id, kind: t.kind) }
        tasks.removeAll { $0.state == "done" }
        saveTasks()
        pushTasks()
    }

    func doubleClicked() {
        if lastOK == nil && promptedLogin { openLogin() } else { refresh() }
    }

    @objc func openLogin() { web.showLogin() }
    @objc func openGPTLogin() {
        guard codexLoginProcess == nil, let binary = CodexUsage.executable else { return }
        let process = Process()
        process.executableURL = binary
        process.arguments = ["login"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async {
                self?.codexLoginProcess = nil
                self?.refreshCodex()
            }
        }
        do { try process.run(); codexLoginProcess = process }
        catch { orbLog("codex login could not start") }
    }

    // MARK: menus

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        for item in makeMenu().items {
            item.menu?.removeItem(item)
            menu.addItem(item)
        }
    }

    func makeMenu() -> NSMenu {
        let m = NSMenu()
        let fmt: (Double?) -> String = { v in v.map { String(format: "%.0f%%", $0) } ?? "N/A" }
        let showingCodex = codexWanted
        let info = NSMenuItem(title: (showingCodex ? "Claude   " : "") + "Session \(fmt(lastSession))   ·   Week \(fmt(lastWeek))", action: nil, keyEquivalent: "")
        info.isEnabled = false
        m.addItem(info)
        if let t = lastOK {
            let df = DateFormatter(); df.dateFormat = "HH:mm"
            let src = NSMenuItem(title: "Source: \(source) · updated \(df.string(from: t))", action: nil, keyEquivalent: "")
            src.isEnabled = false
            m.addItem(src)
        }
        if showingCodex {
            let stale = ((codexPayload as? [String: Any])?["stale"] as? Bool) ?? false
            let ci = NSMenuItem(title: "Codex   Session \(fmt(lastCodexSession))   ·   Week \(fmt(lastCodexWeek))" + (stale ? "   (stale)" : ""), action: nil, keyEquivalent: "")
            ci.isEnabled = false
            m.addItem(ci)
            if !codexSource.isEmpty {
                let cs = NSMenuItem(title: "Source: \(codexSource)" + (stale ? " · run `codex login` if this persists" : ""), action: nil, keyEquivalent: "")
                cs.isEnabled = false
                m.addItem(cs)
            }
        }
        m.addItem(.separator())
        add(m, "Refresh now", #selector(refresh), "r")
        add(m, orb.isVisible ? "Hide orb" : "Show orb", #selector(toggleOrb))
        let sizeItem = NSMenuItem(title: "Size", action: nil, keyEquivalent: "")
        let sm = NSMenu()
        let tip = NSMenuItem(title: "Tip: scroll or pinch on the orb to resize", action: nil, keyEquivalent: "")
        tip.isEnabled = false
        sm.addItem(tip)
        sm.addItem(.separator())
        add(sm, "Bigger", #selector(bigger), "+")
        add(sm, "Smaller", #selector(smaller), "-")
        sm.addItem(.separator())
        for (title, s) in [("Small", 0.8), ("Medium", 1.0), ("Large", 1.25), ("Extra large", 1.5), ("Huge", 2.0)] {
            let it = NSMenuItem(title: title, action: #selector(pickSize(_:)), keyEquivalent: "")
            it.target = self
            it.representedObject = s
            it.state = abs(Double(orb.scale) - s) < 0.01 ? .on : .off
            sm.addItem(it)
        }
        sizeItem.submenu = sm
        m.addItem(sizeItem)
        let styleItem = NSMenuItem(title: "Style", action: nil, keyEquivalent: "")
        let stm = NSMenu()
        for (title, key) in [("Classic orb — Claude only", "classic"), ("Witch's cauldron 🎃 — Claude only", "witch"), ("Claude + Codex", "dual")] {
            let it = NSMenuItem(title: title, action: #selector(pickStyle(_:)), keyEquivalent: "")
            it.target = self
            it.representedObject = key
            it.state = orb.style == key ? .on : .off
            stm.addItem(it)
        }
        styleItem.submenu = stm
        m.addItem(styleItem)
        add(m, "Move to top-right corner", #selector(resetPosition))
        if tasks.contains(where: { $0.state == "done" }) { add(m, "Clear finished chats", #selector(clearFinished)) }
        m.addItem(.separator())
        add(m, lastOK == nil ? "Sign in to claude.ai…" : "Sign in again…", #selector(openLogin))
        add(m, "Sign in with Codex…", #selector(openGPTLogin)).isEnabled = CodexUsage.isInstalled
        let la = add(m, "Launch at login", #selector(toggleLaunchAtLogin))
        la.state = FileManager.default.fileExists(atPath: launchAgentURL.path) ? .on : .off
        m.addItem(.separator())
        add(m, "Quit", #selector(quit), "q")
        return m
    }

    @discardableResult
    func add(_ m: NSMenu, _ title: String, _ sel: Selector, _ key: String = "") -> NSMenuItem {
        let it = NSMenuItem(title: title, action: sel, keyEquivalent: key)
        it.target = self
        m.addItem(it)
        return it
    }

    @objc func toggleOrb() {
        if orb.isVisible { orb.hide() } else { orb.show() }
        UserDefaults.standard.set(!orb.isVisible, forKey: kHiddenKey)
    }
    func resize(by f: CGFloat) {
        let s = min(maxScale, max(minScale, orb.scale * f))
        if abs(s - orb.scale) > 0.001 { orb.setScale(s) }
    }
    @objc func bigger() { resize(by: 1.12) }
    @objc func smaller() { resize(by: 1 / 1.12) }

    @objc func pickSize(_ sender: NSMenuItem) {
        if let s = sender.representedObject as? Double { orb.setScale(CGFloat(s)) }
    }
    @objc func pickStyle(_ sender: NSMenuItem) {
        guard let key = sender.representedObject as? String else { return }
        orb.setStyle(key)
        pushUsage()
        refreshCodex()
        updateStatusIcon()
    }
    func updateStatusIcon() {
        guard let b = statusItem?.button else { return }
        let name = orb.style == "witch" ? "wand.and.stars" : "drop.halffull"
        if let img = NSImage(systemSymbolName: name, accessibilityDescription: "Claude usage") {
            img.isTemplate = true
            b.image = img
            b.title = ""
        } else {
            b.image = nil
            b.title = orb.style == "witch" ? "✦" : "◐"
        }
    }
    @objc func resetPosition() { orb.placeDefault(); orb.show() }
    @objc func quit() { NSApp.terminate(nil) }

    @objc func toggleLaunchAtLogin() {
        let fm = FileManager.default
        if fm.fileExists(atPath: launchAgentURL.path) {
            try? fm.removeItem(at: launchAgentURL)
        } else {
            let plist: [String: Any] = [
                "Label": kAgentLabel,
                "ProgramArguments": ["/usr/bin/open", "-a", Bundle.main.bundlePath],
                "RunAtLoad": true
            ]
            try? fm.createDirectory(at: launchAgentURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            (plist as NSDictionary).write(to: launchAgentURL, atomically: true)
        }
    }

    // Edit menu so ⌘C / ⌘V / ⌘A work in the login window.
    func buildMainMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem(); main.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        let editItem = NSMenuItem(); main.addItem(editItem)
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        edit.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        editItem.submenu = edit
        NSApp.mainMenu = main
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
