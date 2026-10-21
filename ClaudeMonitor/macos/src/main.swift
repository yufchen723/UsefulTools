// Claude Usage Orb — a floating, draggable desktop orb that shows Claude plan usage
// (current 5-hour session on the left, weekly on the right).
// Build with ../build.sh

import Cocoa
import WebKit

let kFrameName   = "ClaudeUsageOrbFrame"
let kScaleKey    = "ClaudeUsageOrbScale"
let kHiddenKey   = "ClaudeUsageOrbHidden"
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
    private var lastTasks: String?
    private var taskCount = 0
    private var hovering = false
    private var zoomWork: DispatchWorkItem?

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
            return p.y >= self.overlay.bounds.height - orbAreaHeight * self.scale
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
        let orbRect = NSRect(x: f.midX - 50, y: f.maxY - orbAreaHeight * scale, width: 100, height: orbAreaHeight * scale)
        let visible = NSScreen.screens.contains { $0.visibleFrame.intersects(orbRect) }
        if !visible { placeDefault() }
    }

    func show() { panel.orderFrontRegardless() }
    func hide() { panel.orderOut(nil) }
    var isVisible: Bool { panel.isVisible }

    /// Size for the current scale and number of task cards, keeping the orb itself fixed on screen.
    private func relayout(oldScale: CGFloat) {
        let old = panel.frame
        let shown = min(taskCount, maxCards)
        var h = orbAreaHeight
        if taskCount > 0 { h += 2 + CGFloat(shown) * cardStep + (taskCount > maxCards ? 18 : 0) }
        let w = taskCount > 0 ? wideWidth : narrowWidth
        let size = NSSize(width: w * scale, height: h * scale)
        let orbCenterY = old.maxY - orbCenterFromTop * oldScale
        let top = orbCenterY + orbCenterFromTop * scale
        panel.setFrame(NSRect(x: old.midX - size.width / 2, y: top - size.height, width: size.width, height: size.height), display: true)
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

    func send(_ payload: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let s = String(data: data, encoding: .utf8) else { return }
        lastPayload = s
        if pageLoaded { js("window.orbUpdate && window.orbUpdate(\(s))") }
    }

    func setTasks(_ tasks: [[String: Any]]) {
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

/// One claude.ai web view shared by sign-in and usage reads, so cookies and
/// Cloudflare clearance are always the same ones.
final class ClaudeSession: NSObject, WKNavigationDelegate, WKUIDelegate, NSWindowDelegate {
    let webView: WKWebView
    private let hostWindow: NSWindow
    private var ready = false
    private var loading = false
    private var waiters: [(Bool) -> Void] = []
    private var popups: [(WKWebView, NSWindow)] = []
    private var loginWindow: NSWindow?
    private var statusLabel: NSTextField?
    private var pollTimer: Timer?
    private var closingLogin = false
    var onLoginFinished: (() -> Void)?
    var isLoginOpen: Bool { loginWindow != nil }

    static let script = """
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

    override init() {
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

    func invalidate() { if loginWindow == nil { ready = false } }

    private var onClaude: Bool { webView.url?.host?.hasSuffix("claude.ai") == true }

    private func ensureReady(_ done: @escaping (Bool) -> Void) {
        if loginWindow != nil { done(onClaude); return }
        if ready && onClaude { done(true); return }
        waiters.append(done)
        if loading { return }
        loading = true
        webView.load(URLRequest(url: URL(string: "https://claude.ai/api/organizations")!))
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
            self.webView.callAsyncJavaScript(Self.script, arguments: [:], in: nil, in: .page) { result in
                switch result {
                case .success(let value):
                    guard let s = value as? String, let d = s.data(using: .utf8),
                          let obj = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] else {
                        orbLog("fetch: unparsable result"); done(.failed("parse")); return
                    }
                    if let data = obj["data"] as? [String: Any] {
                        orbLog("fetch ok: five_hour=\(String(describing: (data["five_hour"] as? [String: Any])?["utilization"])) seven_day=\(String(describing: (data["seven_day"] as? [String: Any])?["utilization"]))")
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
        out.push({ id: c.uuid, title: c.name || '', live: live, req: req,
                   startedMs: ms(c.live_status_started_at), settledMs: ms(c.last_settled_at), updatedMs: ms(c.updated_at),
                   url: '/chat/' + c.uuid });
      }
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
        w.title = "Sign in to Claude (used only to read usage)"
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
        webView.load(URLRequest(url: URL(string: "https://claude.ai/login")!))
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
        pollTimer = Timer.scheduledTimer(withTimeInterval: 2.5, repeats: true) { [weak self] _ in self?.checkSignedIn() }
    }

    @objc private func reloadLogin() { webView.reload() }
    @objc private func doneLogin() { loginWindow?.close() }

    private func checkSignedIn() {
        guard loginWindow != nil, !closingLogin, onClaude else { return }
        let js = "try { const r = await fetch('/api/organizations', {credentials:'include'}); if (!r.ok) return 'http ' + r.status; const j = await r.json(); return (Array.isArray(j) && j.length) ? 'ok' : 'empty'; } catch (e) { return 'err ' + e; }"
        webView.callAsyncJavaScript(js, arguments: [:], in: nil, in: .page) { [weak self] res in
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
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    var orb: OrbWindowController!
    let web = ClaudeSession()
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
        if let b = statusItem.button {
            if let img = NSImage(systemSymbolName: "drop.halffull", accessibilityDescription: "Claude usage") {
                img.isTemplate = true
                b.image = img
            } else {
                b.title = "◐"
            }
        }
        let m = NSMenu()
        m.delegate = self
        statusItem.menu = m

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
                        self.orb.send(["status": "login"])
                        if !self.promptedLogin { self.promptedLogin = true; self.openLogin() }
                    } else {
                        self.orb.send(["status": "error"])
                    }
                }
            }
        }
    }

    func deliver(_ d: [String: Any], source: String) {
        func win(_ key: String) -> Any {
            guard let w = d[key] as? [String: Any] else { return NSNull() }
            return ["pct": w["utilization"] ?? NSNull(), "resetsAt": w["resets_at"] ?? NSNull()]
        }
        func pct(_ key: String) -> Double? { ((d[key] as? [String: Any])?["utilization"] as? NSNumber)?.doubleValue }
        lastSession = pct("five_hour") ?? 0
        lastWeek = pct("seven_day") ?? 0
        self.source = source
        lastOK = Date()
        orb.send(["status": "ok", "session": win("five_hour"), "week": win("seven_day")])
    }

    // MARK: chat activity

    func loadTasks() {
        if let d = UserDefaults.standard.data(forKey: kTasksKey),
           let t = try? JSONDecoder().decode([OrbTask].self, from: d) { tasks = t }
    }
    func saveTasks() {
        if let d = try? JSONEncoder().encode(tasks) { UserDefaults.standard.set(d, forKey: kTasksKey) }
    }
    func pushTasks() {
        orb.setTasks(tasks.map { t in
            var o: [String: Any] = ["id": t.id, "title": t.title, "state": t.state, "bucket": t.bucket, "startedAt": t.startedAt]
            if let e = t.endedAt { o["endedAt"] = e }
            return o
        })
    }

    func pollTasks() {
        if polling || web.isLoginOpen || lastOK == nil { return }
        polling = true
        let tracked = tasks.filter { $0.state != "done" }.map { $0.id }
        web.fetchSessions(tracked: tracked) { [weak self] list in
            guard let self = self else { return }
            self.polling = false
            if let list = list { self.ingest(list) }
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
            let busy = !live.isEmpty && !["done", "idle", "completed", "settled", "finished", "stopped", "none"].contains(live)
            let perm = req > 0 || live.contains("permission") || live.contains("approv") || live.contains("action") || live.contains("input") || live.contains("wait")
            if let i = tasks.firstIndex(where: { $0.id == id }) {
                var t = tasks[i]
                let before = (t.state, t.title, t.bucket)
                if busy {
                    if t.state == "done" { t.startedAt = startedMs > 0 ? startedMs : now; t.endedAt = nil }
                    else if startedMs > 0 && abs(startedMs - t.startedAt) > 60_000 { t.startedAt = startedMs }
                    t.state = perm ? "permission" : "running"
                    t.idleSeen = 0
                } else if t.state != "done" {
                    t.idleSeen += 1
                    if t.idleSeen >= 2 {
                        t.state = "done"
                        t.endedAt = settledMs > t.startedAt ? settledMs : now
                    }
                }
                t.title = title
                t.bucket = live
                if !url.isEmpty { t.url = url }
                if before != (t.state, t.title, t.bucket) { changed = true; orbLog("chat '\(title)' → \(t.state) (\(live))") }
                tasks[i] = t
            } else if busy {
                tasks.append(OrbTask(id: id, title: title, url: url, state: perm ? "permission" : "running",
                                     bucket: live, startedAt: startedMs > 0 ? startedMs : now, endedAt: nil, idleSeen: 0))
                changed = true
                orbLog("chat '\(title)' started (\(live), req=\(req))")
            }
        }
        if changed { saveTasks(); pushTasks() }
    }

    func cardAction(id: String, action: String) {
        guard let i = tasks.firstIndex(where: { $0.id == id }) else { return }
        let t = tasks[i]
        openChat(t)
        if action == "check" {
            tasks.remove(at: i)
            saveTasks()
            pushTasks()
        }
    }

    func openChat(_ t: OrbTask) {
        let path = t.url.isEmpty ? "/chat/" + t.id : t.url
        let ws = NSWorkspace.shared
        // Prefer the desktop app: try its URL scheme first, then just bring the app forward.
        if let deep = URL(string: "claude://claude.ai" + path), ws.urlForApplication(toOpen: deep) != nil {
            orbLog("open chat via \(deep.absoluteString)")
            ws.open(deep)
            return
        }
        if let app = ws.urlForApplication(withBundleIdentifier: "com.anthropic.claudefordesktop") {
            orbLog("open Claude app (no deep link) for \(path)")
            let cfg = NSWorkspace.OpenConfiguration()
            cfg.activates = true
            ws.openApplication(at: app, configuration: cfg, completionHandler: nil)
            return
        }
        if let web = URL(string: "https://claude.ai" + path) { ws.open(web) }
    }

    @objc func clearFinished() {
        tasks.removeAll { $0.state == "done" }
        saveTasks()
        pushTasks()
    }

    func doubleClicked() {
        if lastOK == nil && promptedLogin { openLogin() } else { refresh() }
    }

    @objc func openLogin() { web.showLogin() }

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
        let fmt: (Double?) -> String = { v in v.map { String(format: "%.0f%%", $0) } ?? "--" }
        let info = NSMenuItem(title: "Session \(fmt(lastSession))   ·   Week \(fmt(lastWeek))", action: nil, keyEquivalent: "")
        info.isEnabled = false
        m.addItem(info)
        if let t = lastOK {
            let df = DateFormatter(); df.dateFormat = "HH:mm"
            let src = NSMenuItem(title: "Source: \(source) · updated \(df.string(from: t))", action: nil, keyEquivalent: "")
            src.isEnabled = false
            m.addItem(src)
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
        add(m, "Move to top-right corner", #selector(resetPosition))
        if tasks.contains(where: { $0.state == "done" }) { add(m, "Clear finished chats", #selector(clearFinished)) }
        m.addItem(.separator())
        add(m, lastOK == nil ? "Sign in to claude.ai…" : "Sign in again…", #selector(openLogin))
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
