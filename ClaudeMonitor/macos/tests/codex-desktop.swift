func event(_ type: String, _ turn: String = "turn1") -> [String: Any] {
    ["type": "event_msg", "timestamp": "2026-10-23T19:00:00Z", "payload": ["type": type, "turn_id": turn, "started_at": 1792782000]]
}
var activity = CodexDesktopSessions.Activity()
activity.apply(event("task_started")); assert(activity.state == "running")
assert(activity.started == 1792782000000)
activity.apply(event("task_complete", "older")); assert(activity.state == "running")
activity.apply(event("task_complete")); assert(activity.state == "done")
activity.apply(event("task_started", "turn2")); assert(activity.state == "running" && activity.ended == 0)
activity.apply(event("turn_aborted", "turn2")); assert(activity.state == "done")
let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: directory) }
let path = directory.appendingPathComponent("rollout.jsonl")
func line(_ type: String) throws -> Data {
    var d = try JSONSerialization.data(withJSONObject: event(type)); d.append(10); return d
}
try line("task_started").write(to: path)
let reader = CodexDesktopSessions(home: directory, hooks: directory)
assert(reader.activity(at: path.path)!.state == "running")
let finish = try line("task_complete")
let file = try FileHandle(forWritingTo: path); try file.seekToEnd()
try file.write(contentsOf: finish.prefix(finish.count / 2))
assert(reader.activity(at: path.path)!.state == "running")
try file.write(contentsOf: finish.suffix(finish.count - finish.count / 2)); try file.close()
assert(reader.activity(at: path.path)!.state == "done")
try line("task_started").write(to: path, options: .atomic)
assert(reader.activity(at: path.path)!.state == "running")
// A database fixture proves desktop filtering and excludes CLI and subagent sessions.
var db: OpaquePointer?
assert(sqlite3_open(directory.appendingPathComponent("state_5.sqlite").path, &db) == SQLITE_OK)
let sql = "CREATE TABLE threads(id TEXT, name TEXT, title TEXT, rollout_path TEXT, cwd TEXT, updated_at INTEGER, archived INTEGER, originator TEXT, source TEXT, thread_source TEXT DEFAULT 'user');"
assert(sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK)
for (id, origin, source) in [("11111111-1111-1111-1111-111111111111", "Codex Desktop", "vscode"), ("22222222-2222-2222-2222-222222222222", "codex_cli_rs", "cli"), ("33333333-3333-3333-3333-333333333333", "Codex Desktop", "subagent")] {
    let insert = "INSERT INTO threads VALUES('\(id)',NULL,'Test desktop','\(path.path)','/tmp',\(Int(Date().timeIntervalSince1970)),0,'\(origin)','\(source)','user');"
    assert(sqlite3_exec(db, insert, nil, nil, nil) == SQLITE_OK)
}
assert(sqlite3_exec(db, "INSERT INTO threads VALUES('44444444-4444-4444-4444-444444444444',NULL,'Internal job','/tmp/unused','/tmp',0,0,'Codex Desktop','vscode','guardian_review');", nil, nil, nil) == SQLITE_OK)
sqlite3_close(db)
let foreground = reader.foregroundIDs()!
assert(foreground.contains("11111111-1111-1111-1111-111111111111"))
assert(foreground.contains("22222222-2222-2222-2222-222222222222"))
assert(!foreground.contains("33333333-3333-3333-3333-333333333333"))
assert(!foreground.contains("44444444-4444-4444-4444-444444444444"))
assert(!foreground.contains("unindexed-suggestion-job"))
print("PASS: foreground desktop/CLI retained; subagents, internal jobs and unindexed suggestions excluded")
let rows = reader.read(tracked: [])
assert(rows.count == 1 && rows[0]["kind"] as? String == "codex-desktop")
assert(rows[0]["url"] as? String == "codex://threads/11111111-1111-1111-1111-111111111111")
let hookFile = directory.appendingPathComponent("11111111-1111-1111-1111-111111111111.json")
let permissionHook: [String: Any] = ["id": "11111111-1111-1111-1111-111111111111", "turnId": "turn1", "state": "permission", "updatedAt": 1792782001000.0, "pendingApprovals": ["tool": 1]]
try JSONSerialization.data(withJSONObject: permissionHook).write(to: hookFile)
let waitingRows = reader.read(tracked: [])
assert(waitingRows[0]["live"] as? String == "permission" && waitingRows[0]["req"] as? Int == 1)
try FileManager.default.removeItem(at: hookFile)
assert(reader.read(tracked: [])[0]["live"] as? String == "running")
print("PASS: desktop start/finish/interruption, turn matching, split append, file rotation, database filtering and deep link")
if CommandLine.arguments.contains("--live") {
    let rows = CodexDesktopSessions().read(tracked: [])
    let running = rows.filter { $0["live"] as? String == "running" }
    print("Live desktop records: \(rows.count); running: \(running.count)")
    for row in running { print("Active desktop thread: \(row["id"] ?? "")") }
}

var approvalActivity = CodexDesktopSessions.Activity()
approvalActivity.apply(event("task_started"))
var hook: [String: Any] = ["turnId": "turn1", "state": "permission", "updatedAt": 1792782001000.0, "pendingApprovals": ["tool-a": 1, "tool-b": 1]]
assert(CodexDesktopSessions.displayState(activity: approvalActivity, hook: hook) == "permission")
hook["turnId"] = "older"
assert(CodexDesktopSessions.displayState(activity: approvalActivity, hook: hook) == "running")
hook["turnId"] = "turn1"; hook["updatedAt"] = 1
assert(CodexDesktopSessions.displayState(activity: approvalActivity, hook: hook) == "running")
hook["updatedAt"] = 1792782001000.0; hook["pendingApprovals"] = [:] as [String: Any]
assert(CodexDesktopSessions.displayState(activity: approvalActivity, hook: hook) == "running")
hook["pendingApprovals"] = ["tool-a": 1]
approvalActivity.apply(event("task_complete"))
assert(CodexDesktopSessions.displayState(activity: approvalActivity, hook: hook) == "done")
print("PASS: approval merge, previous-turn rejection, stale hook rejection, resolved approval and completion precedence")
