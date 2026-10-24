let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let orb = OrbWindowController(scale: 1)
orb.show()
@MainActor func evaluate(_ code: String) async throws -> Any? {
    try await withCheckedThrowingContinuation { continuation in
        orb.webView.evaluateJavaScript(code) { value, error in
            if let error = error { continuation.resume(throwing: error) }
            else { continuation.resume(returning: value) }
        }
    }
}
func check(_ condition: Bool, _ message: String) {
    if !condition { print("FAIL: \(message)"); exit(1) }
}
Task { @MainActor in
    do {
        for _ in 0..<100 {
            if (try? await evaluate("typeof window.orbTasks === 'function'")) as? Bool == true { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        let started = Date().timeIntervalSince1970 * 1000 - 60000
        let fixture: [[String: Any]] = [
            ["id":"running", "title":"AI 工作流程视频制作", "kind":"code-cloud", "state":"running", "startedAt":started],
            ["id":"done", "title":"中文标题测试：Claude 与 Codex", "kind":"code-local", "state":"done", "startedAt":started, "endedAt":started+30000],
            ["id":"permission", "title":"Codex approval", "kind":"code-cloud", "state":"permission", "startedAt":started]
        ]
        var cases = 0
        for scale in [0.8, 1.0, 1.5] {
            orb.setScale(CGFloat(scale))
            orb.setTasks(fixture)
            for style in ["classic", "witch", "dual", "apple", "nature", "classic", "crystal", "dual", "witch", "nature", "apple"] {
                orb.setStyle(style)
                orb.send(["status":"ok", "session":["pct":42], "week":["pct":59], "codex": codexStyles.contains(style) ? ["session":NSNull(), "week":["pct":2]] : NSNull()])
                try await Task.sleep(nanoseconds: 80_000_000)
                if style == "witch" {
                    check(try await evaluate("getComputedStyle(document.querySelector('[data-id=running] .t1')).fontSize") as? String == "12px", "Chinese title font size")
                    check(try await evaluate("document.querySelector('[data-id=running] .t1').classList.contains('cjk')") as? Bool == true, "Chinese title class")
                }
                let result = try await evaluate("""
                (() => {
                  const cards = [...document.querySelectorAll('.task,.skc')];
                  if (cards.map(c=>c.dataset.id).join(',') !== 'permission,done,running') throw Error('cards lost or reordered');
                  for (const card of cards) {
                    const target=card.querySelector('.btn,.skb') || card.querySelector('.txt,.skt');
                    const r=target.getBoundingClientRect();
                    const actual=JSON.parse(window.orbClickAt(r.x+r.width/2,r.y+r.height/2));
                    const expected=card.dataset.id==='done'?'check':card.dataset.id==='permission'?'permit':'open';
                    if(actual.id!==card.dataset.id || actual.action!==expected) throw Error('hit target changed');
                  }
                  if(!cards[2].querySelector('.t2,.sk2').textContent.includes('1m')) throw Error('running timer lost');
                  if(!cards[1].querySelector('.t2,.sk2').textContent.includes('30s')) throw Error('done duration changed');
                  const r=cards[2].querySelector('.txt,.skt').getBoundingClientRect();
                  return {x:r.x+r.width/2,y:r.y+r.height/2,bottom:cards[2].getBoundingClientRect().bottom,
                    top:document.getElementById('tasks').getBoundingClientRect().top};
                })()
                """) as! [String: Any]
                check(orb.quad == (style == "dual"), "native layout mode")
                
                check(abs((result["top"] as! Double) - (orbGeometry(style).area + 2)) < 1, "task top")
                check((result["bottom"] as! Double) * scale <= orb.panel.frame.height + 1, "cards clipped")
                let point = NSPoint(x:(result["x"] as! Double)*scale,y:orb.overlay.bounds.height-(result["y"] as! Double)*scale)
                let hit: (String,String) = await withCheckedContinuation { continuation in
                    orb.cardAction(at: point) { continuation.resume(returning: ($0,$1)) }
                }
                check(hit.0 == "running" && hit.1 == "open", "native coordinate conversion")
                cases += 1
            }
        }

        // Style filtering must preserve hidden tasks and size the native panel from visible cards.
        var desktop = fixture[0]; desktop["id"] = "codex-desktop"; desktop["kind"] = "codex-desktop"
        var cli = fixture[1]; cli["id"] = "codex-cli"; cli["kind"] = "codex-local"
        for style in ["dual", "classic", "apple", "witch", "nature", "crystal", "dual"] {
            orb.setStyle(style)
            orb.setTasks(fixture + [desktop, cli])
            check(try await evaluate("document.querySelectorAll('.task,.skc').length") as? Int == (codexStyles.contains(style) ? 5 : 3), "provider filtering")
            check(try await evaluate("document.querySelectorAll('.task.codex,.skc.codex').length") as? Int == (codexStyles.contains(style) ? 2 : 0), "hidden Codex cards")
        }
        orb.setTasks([desktop, cli])
        orb.setStyle("classic")
        check(try await evaluate("document.querySelectorAll('.task,.skc').length") as? Int == 0, "Codex-only list hidden")
        let emptyHeight = orb.panel.frame.height
        orb.setStyle("dual")
        check(try await evaluate("document.querySelectorAll('.task,.skc').length") as? Int == 2, "hidden tasks restored without polling")
        check(orb.panel.frame.height > emptyHeight, "native height follows visible task count")
        print("PASS: Claude-only hides desktop and CLI Codex tasks; dual restores cached tasks immediately")

        let reset = "2026-10-30T17:43:00Z"
        var visualCases = 0
        for scale in [0.6, 0.8, 1.0, 1.25, 1.5, 2.5] {
            orb.setScale(CGFloat(scale))
            for style in ["classic", "witch", "dual", "apple", "crystal"] {
                orb.setStyle(style)
                for count in [0, 1, 3, 5, 6] {
                    let cards = (0..<count).map { index -> [String: Any] in
                        var card = fixture[index % 3]; card["id"] = "card-\(index)"; return card
                    }
                    orb.setTasks(cards)
                    orb.send(["status":"ok", "session":["pct":42,"resetsAt":reset], "week":["pct":59,"resetsAt":reset],
                              "codex":["session":NSNull(),"week":["pct":5,"resetsAt":reset]]])
                    for hover in [false,true] {
                        _ = try await evaluate("window.orbHover(\(hover))")
                        try await Task.sleep(nanoseconds: 30_000_000)
                        let data = try await evaluate("""
                        (()=>{
                          const rect = e=>e.getBoundingClientRect();
                          const pills=[...document.querySelectorAll('.pill')].filter(e=>getComputedStyle(e).display!=='none');
                          for(const p of pills){
                            const t=p.querySelector('.value'), r=rect(p), tr=rect(t);
                            if(tr.left<r.left-1 || tr.right>r.right+1 || tr.top<r.top-1 || tr.bottom>r.bottom+1) throw Error('time outside pill '+p.id);
                            if(r.left < -1 || r.right > innerWidth+1) throw Error('pill outside window');
                          }
                          const cards=[...document.querySelectorAll('.task,.skc')];
                          if(cards.length>5) throw Error('card cap');
                          const more=document.getElementById('more');
                          const bottom=more?rect(more).bottom:cards.length?rect(cards.at(-1)).bottom:0;
                          return {bottom, count:cards.length, more:!!more};
                        })()
                        """) as! [String:Any]
                        check(data["count"] as? Int == min(count,5), "card count")
                        check(data["more"] as? Bool == (count>5), "overflow counter")
                        check((data["bottom"] as! Double)*scale <= orb.panel.frame.height+1, "window clips cards or counter")
                        visualCases += 1
                        if scale == 1 && count == 3 {
                            try await Task.sleep(nanoseconds: 200_000_000)
                            let snapshot: NSImage = try await withCheckedThrowingContinuation { continuation in
                                orb.webView.takeSnapshot(with:nil) { image,error in
                                    if let image = image { continuation.resume(returning:image) }
                                    else { continuation.resume(throwing:error ?? NSError(domain:"snapshot",code:1)) }
                                }
                            }
                            let png = NSBitmapImageRep(data:snapshot.tiffRepresentation!)!.representation(using:.png,properties:[:])!
                            try png.write(to:URL(fileURLWithPath:CommandLine.arguments[1]).appendingPathComponent("\(style)-\(hover ? "hover" : "normal").png"))
                        }
                    }
                }
                for status in ["loading","login","error"] {
                    orb.send(["status":status,"codex":NSNull()])
                    _ = try await evaluate("window.orbHover(true)")
                    check(try await evaluate("document.body.classList.contains('quad')") as? Bool == (style == "dual"), "offline changed layout")
                }
            }
        }
        print("PASS: \(visualCases) visual cases: 5 styles, 6 scales, 5 task counts, hover on/off; complete dates fit; overflow counter and error/login/loading states")
        orb.setTasks(fixture)
        // Updates after switching still replace state and dismiss cards normally.
        var updated = fixture
        updated[0]["state"] = "done"; updated[0]["endedAt"] = started + 45000
        orb.setTasks(updated)
        check(try await evaluate("document.querySelector('[data-id=running]').classList.contains('done')") as? Bool == true, "completion after switch")
        orb.setTasks([fixture[2]])
        check(try await evaluate("document.querySelectorAll('.task,.skc').length") as? Int == 1, "dismissal after switch")
        orb.setTasks([])
        check(try await evaluate("document.querySelectorAll('.task,.skc').length") as? Int == 0, "empty cards")
        print("PASS: \(cases) native WebKit style/scale transitions; card identity/status, timers, button hit tests, native click coordinates, clipping, completion, dismissal and empty state")
        app.terminate(nil)
    } catch { print("FAIL: \(error)"); exit(1) }
}
DispatchQueue.main.asyncAfter(deadline: .now()+60) { print("FAIL: check timed out"); exit(1) }
app.run()
