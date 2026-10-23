func window(_ used: Any, _ minutes: Int) -> [String: Any] {
    ["usedPercent": used, "windowDurationMins": minutes, "resetsAt": 1793382191]
}
let weekly: [String: Any] = ["primary": window(0, 10080), "secondary": NSNull()]
let parsed = CodexUsage.normaliseResponse(["rateLimitsByLimitId": ["codex": weekly]])!
assert(parsed["five_hour"] == nil)
assert((parsed["seven_day"] as! [String: Any])["utilization"] as! Double == 0)
assert((parsed["seven_day"] as! [String: Any])["resets_at"] != nil)
let both = CodexUsage.normaliseResponse(["rateLimits": ["primary": window(12, 300), "secondary": window(43, 10080)]])!
assert((both["five_hour"] as! [String: Any])["utilization"] as! Double == 12)
assert((both["seven_day"] as! [String: Any])["utilization"] as! Double == 43)
let missing = CodexUsage.normaliseResponse(["rateLimits": ["primary": window(NSNull(), 300)]])!
assert(missing.isEmpty)
assert(CodexUsage.normaliseResponse(["rateLimits": ["primary": window(50, 15)]])!.isEmpty)
assert(CodexUsage.normaliseResponse(["rateLimitsByLimitId": [:], "rateLimits": weekly])!.isEmpty)
assert(CodexUsage.normaliseResponse([:]) == nil)
print("PASS: weekly-only, zero, reset, dual-window, missing, unknown duration, bucket precedence, malformed response")
if CommandLine.arguments.contains("--live") {
    guard let result = CodexUsage.read() else { fatalError("Live app-server read failed") }
    print("Live source: \(result.source); windows: \(result.data)")
}
