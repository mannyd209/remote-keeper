// Reading the Claude app's sessions (read-only), knowing whether each one's Remote Control is on,
// and turning it back on.
//
// Reads (never writes) ~/Library/Application Support/Claude/claude-code-sessions/*/*/local_*.json
// and Claude's log. Reconnecting = open the session in the Claude app and type Claude's own
// /remote-control command (handled by the app, so it uses no Claude usage). If that doesn't take,
// it falls back to one fixed message ("Reply only: ok"), since a session reconnects by itself once
// it runs a turn. Nothing else is ever typed, and only into the Claude process.

import AppKit
import ApplicationServices
import Foundation

let claudeBundleID = "com.anthropic.claudefordesktop"
let wakeText = "Remote Keeper: this message reconnects Remote Control for this session. Reply only: ok"
let remoteControlCommand = "/remote-control"
let claudeLog = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Claude/main.log")
let sessionsRoot = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Claude/claude-code-sessions")

// MARK: - Claude sessions (read-only)

struct Session {
    let id: String
    let title: String
    let cwd: String
    let pinned: Bool
    let archived: Bool
    let lastTurn: Double   // ms since 1970
    let lastActivity: Double // ms since 1970; keeps moving while a turn is running
    let turns: Int
    let userEnabled: Bool? // Claude's per-session Remote Control switch (nil: never set)
    /// Its claude.ai/code session id (the newest), so the phone can open this exact session in the
    /// Claude app. nil until Remote Control has connected it at least once.
    var remoteId: String? = nil
    /// A run of a scheduled task (Claude starts these by itself; Remote Control doesn't reach them).
    var scheduled: Bool = false
}

/// Every session file, read only when it changed since the last look. The files add up to tens of
/// megabytes, and this runs every 10 seconds, so re-reading them all each time cost real CPU and memory.
func allSessions() -> [Session] {
    let fm = FileManager.default
    var found: [Session] = []
    var seen = Set<String>()
    for account in (try? fm.contentsOfDirectory(atPath: sessionsRoot.path)) ?? [] {
        let accountDir = sessionsRoot.appendingPathComponent(account)
        for org in (try? fm.contentsOfDirectory(atPath: accountDir.path)) ?? [] {
            let orgDir = accountDir.appendingPathComponent(org)
            for file in (try? fm.contentsOfDirectory(atPath: orgDir.path)) ?? [] where file.hasPrefix("local_") && file.hasSuffix(".json") {
                let path = orgDir.appendingPathComponent(file).path
                seen.insert(path)
                if let session = sessionCache.session(at: path) { found.append(session) }
            }
        }
    }
    sessionCache.keep(only: seen)
    return found
}

private let sessionCache = SessionCache()

private final class SessionCache {
    private let lock = NSLock()
    private var entries: [String: (modified: timespec, size: off_t, session: Session?)] = [:]

    func session(at path: String) -> Session? {
        var info = stat()
        guard stat(path, &info) == 0 else { return nil }
        lock.lock()
        if let entry = entries[path], entry.modified.tv_sec == info.st_mtimespec.tv_sec,
           entry.modified.tv_nsec == info.st_mtimespec.tv_nsec, entry.size == info.st_size {
            lock.unlock()
            return entry.session
        }
        lock.unlock()
        let session = autoreleasepool { SessionCache.read(path) }
        lock.lock()
        entries[path] = (info.st_mtimespec, info.st_size, session)
        lock.unlock()
        return session
    }

    func keep(only paths: Set<String>) {
        lock.lock()
        entries = entries.filter { paths.contains($0.key) }
        lock.unlock()
    }

    private static func read(_ path: String) -> Session? {
        guard let data = FileManager.default.contents(atPath: path),
              let d = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let id = d["sessionId"] as? String else { return nil }
        let lastTurn = (d["lastTurnEdgeAt"] as? Double) ?? (d["lastActivityAt"] as? Double) ?? 0
        return Session(
            id: id,
            title: (d["title"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "Untitled",
            cwd: d["cwd"] as? String ?? "",
            pinned: d["isStarred"] as? Bool == true,
            archived: d["isArchived"] as? Bool == true,
            lastTurn: lastTurn,
            lastActivity: (d["lastActivityAt"] as? Double) ?? lastTurn,
            turns: d["completedTurns"] as? Int ?? 0,
            userEnabled: d["remoteControlUserEnabled"] as? Bool,
            remoteId: (d["bridgeSessionIds"] as? [String])?.last(where: { Self.isRemoteId($0) }),
            scheduled: (d["scheduledTaskId"] as? String).map { !$0.isEmpty } ?? false)
    }

    /// claude.ai session ids are short and URL-safe (like "session_01AbC…"); anything else is ignored
    /// rather than put in a link.
    private static func isRemoteId(_ id: String) -> Bool {
        !id.isEmpty && id.count <= 128 && id.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") }
    }
}

/// Sessions you can wake: not archived, not a scheduled task's run (Claude starts those by itself
/// and Remote Control doesn't reach them), and their folder still exists.
func liveSessions() -> [Session] {
    allSessions()
        .filter { !$0.archived && !$0.scheduled && FileManager.default.fileExists(atPath: $0.cwd) }
        .sorted { $0.lastTurn > $1.lastTurn }
}

func session(_ id: String) -> Session? { allSessions().first { $0.id == id } }

func claudeApp() -> NSRunningApplication? {
    NSRunningApplication.runningApplications(withBundleIdentifier: claudeBundleID).first
}

/// Whether each session's Remote Control is on right now, from Claude's log since it started:
/// "Enabling/Disabling remote control for session X" (its switch, or /remote-control), and
/// "Remote control enabled" after "Mapping internal session X" (it reconnected after a turn).
/// A session with no log entry is on if it ran a turn since Claude started (with "Connect new
/// sessions to Remote Control" on, a turn reconnects it), and its switch isn't off.
struct RemoteControlStatus {
    let launch: Date?
    let events: [String: Bool]

    static func now() -> RemoteControlStatus {
        let launch = claudeApp()?.launchDate
        guard let launch else { return RemoteControlStatus(launch: nil, events: [:]) }
        return RemoteControlStatus(launch: launch, events: cache.events(since: launch))
    }

    /// Sessions Claude has started since it launched (only those can take /remote-control).
    static func startedSessions() -> Set<String> {
        guard let launch = claudeApp()?.launchDate else { return [] }
        return cache.started(since: launch)
    }

    func isOn(_ s: Session) -> Bool {
        guard let launch else { return false }
        if s.userEnabled == false { return false }
        if let on = events[s.id] { return on }
        return s.lastTurn / 1000 > launch.timeIntervalSince1970
    }

    /// The last thing Claude's log says about each session's Remote Control since `start`.
    static func logEvents(since start: Date) -> [String: Bool] {
        autoreleasepool {
            guard let handle = try? FileHandle(forReadingFrom: claudeLog) else { return [:] }
            defer { try? handle.close() }
            let size = handle.seekToEndOfFile()
            handle.seek(toFileOffset: size > 3_000_000 ? size - 3_000_000 : 0)
            var parser = Parser(since: logStamp(start.addingTimeInterval(-1)))
            parser.read(String(decoding: handle.readDataToEndOfFile(), as: UTF8.self))
            return parser.events
        }
    }

    /// Reads Claude's log for what each session's Remote Control did.
    private struct Parser {
        let since: String
        var events: [String: Bool] = [:]
        var started: Set<String> = []   // sessions Claude started (it logs "Mapping internal session X")
        var recent: String?   // the session the next "Remote control enabled" belongs to

        init(since: String) { self.since = since }

        mutating func read(_ text: String) {
            for line in text.split(separator: "\n") where line.contains("emote control") || line.contains("Mapping internal session ") {
                guard line.prefix(19) >= since else { continue }
                if let id = RemoteControlStatus.sessionId(after: "Enabling remote control for session ", in: line) {
                    recent = id
                } else if let id = RemoteControlStatus.sessionId(after: "Disabling remote control for session ", in: line) {
                    events[id] = false
                    if recent == id { recent = nil }
                } else if let id = RemoteControlStatus.sessionId(after: "Mapping internal session ", in: line) {
                    recent = id
                    started.insert(id)
                } else if line.contains("Remote control enabled"), let id = recent {
                    events[id] = true
                    recent = nil
                }
            }
        }
    }

    /// The watcher checks often (on every log change), so it reads only what Claude added to its
    /// log since the last look, instead of the last 3 MB each time.
    private static let cache = Cache()

    private final class Cache {
        private let lock = NSLock()
        private var launch: Date?
        private var offset: UInt64 = 0
        private var parser = Parser(since: "")

        func events(since launch: Date) -> [String: Bool] { read(since: launch).events }

        func started(since launch: Date) -> Set<String> { read(since: launch).started }

        private func read(since launch: Date) -> Parser {
            lock.lock(); defer { lock.unlock() }
            return autoreleasepool {
                guard let handle = try? FileHandle(forReadingFrom: claudeLog) else { return Parser(since: "") }
                defer { try? handle.close() }
                let size = handle.seekToEndOfFile()
                if self.launch != launch || size < offset {   // Claude restarted, or started a new log
                    self.launch = launch
                    offset = size > 3_000_000 ? size - 3_000_000 : 0
                    parser = Parser(since: logStamp(launch.addingTimeInterval(-1)))
                }
                handle.seek(toFileOffset: offset)
                let data = handle.readDataToEndOfFile()
                // Only whole lines: the last one may still be being written.
                guard let lastNewline = data.lastIndex(of: UInt8(ascii: "\n")) else { return parser }
                let whole = data[data.startIndex...lastNewline]
                offset += UInt64(whole.count)
                parser.read(String(decoding: whole, as: UTF8.self))
                return parser
            }
        }
    }

    fileprivate static func sessionId(after marker: String, in line: Substring) -> String? {
        guard let range = line.range(of: marker) else { return nil }
        return line[range.upperBound...].split(separator: " ").first.map(String.init)
    }
}

// MARK: - Plan usage (read-only)

let planUsageFile = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Claude/plan-usage-history.json")

/// The newest plan-usage reading the Claude app saved: it writes one about every 5 minutes while
/// it's open (percent used per limit: "fh" the 5-hour limit, "sd" weekly across all models, plus
/// per-model weekly limits when Claude records them). Claude doesn't save reset times, so they're
/// worked out from its 30 days of readings (see estimateResets). Sent to the phone as
/// {"at": ms, "limits": {"fh": 7, "sd": 5}, "resets": {"fh": ms, "sd": ms}}. nil with no reading.
func planUsage() -> [String: Any]? {
    autoreleasepool {
        guard let data = try? Data(contentsOf: planUsageFile),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let samples = json["samples"] as? [[String: Any]],
              let last = samples.last,
              let at = last["t"] as? Double,
              let limits = last["u"] as? [String: Any] else { return nil }
        let percents = limits.compactMapValues { ($0 as? NSNumber)?.doubleValue }
        guard !percents.isEmpty else { return nil }
        let readings = samples.compactMap { s -> (t: Double, u: [String: Double])? in
            guard let t = s["t"] as? Double, let u = s["u"] as? [String: Any] else { return nil }
            return (t, u.compactMapValues { ($0 as? NSNumber)?.doubleValue })
        }
        let now = Date().timeIntervalSince1970 * 1000
        var resets = estimateResets(readings, now: now, firstMessage: firstClaudeMessage(after:))
        var shown = percents
        var labels: [String: String] = [:]
        if let menu = TrayUsage.latest, now - menu.at < 6 * 3_600_000 {
            menu.correct(&resets, limits: &shown, labels: &labels, now: now, firstMessage: firstClaudeMessage(after:))
        }
        // Claude's usage popup gives the exact reset times (the menu rounds them): they win while
        // they're still ahead, and its percents count when they're newer than the file's.
        if let popup = PopupUsage.latest, now - popup.at < 24 * 3_600_000 {
            for row in popup.rows {
                let key = TrayUsage.keys[row.label] ?? labels.first(where: { $0.value == row.label })?.key
                guard let key else { continue }
                if popup.at > at - 60_000 { shown[key] = row.percent }
                if let reset = row.resetAt, reset > now { resets[key] = reset }
            }
        }
        var result: [String: Any] = ["at": Int(at), "limits": shown, "resets": resets.mapValues { Int($0) }]
        if !labels.isEmpty { result["labels"] = labels }
        return result
    }
}

/// When the 5-hour and weekly limits reset next (ms since 1970), from Claude's readings.
/// A reset shows up as a sudden drop. The weekly reset comes at the same time each week, so the
/// tightest drop on record is repeated weekly. A 5-hour window starts with the first use after a
/// reset and ends 5 hours later; with no use since the last reset there's no window running.
/// `firstMessage(after:)` gives the exact time of the first message sent on this Mac after a time
/// (from Claude's log), which is when a window started if the work was done here.
func estimateResets(_ readings: [(t: Double, u: [String: Double])], now: Double,
                    firstMessage: (Double) -> Double? = { _ in nil }) -> [String: Double] {
    var resets: [String: Double] = [:]
    let hour = 3_600_000.0, week = 7 * 24 * hour
    func drops(_ key: String) -> [(before: Double, after: Double, index: Int)] {
        var out: [(Double, Double, Int)] = []
        var prev: (t: Double, v: Double)?
        for (i, r) in readings.enumerated() {
            guard let v = r.u[key] else { continue }
            if let p = prev, v < p.v - 3, v <= p.v / 2 { out.append((p.t, r.t, i)) }
            prev = (r.t, v)
        }
        return out
    }
    // Weekly: the narrowest drop gives the time of week; the next one after now is the reset.
    if let best = drops("sd").min(by: { ($0.after - $0.before) < ($1.after - $1.before) }), best.after - best.before <= 2 * hour {
        var next = (best.before + best.after) / 2
        while next <= now { next += week }
        resets["sd"] = next
    }
    // 5-hour: the window starts with the first message after the last reset (a drop in the
    // readings). Best: that message's exact time in Claude's log. Otherwise from the readings: if
    // the first one after the drop already shows use, it started at the reset itself; else
    // between the last reading at 0 and the first one above it.
    if let lastDrop = drops("fh").last, let latest = readings.last(where: { $0.u["fh"] != nil }), (latest.u["fh"] ?? 0) > 0 {
        let after = readings[lastDrop.index...].filter { $0.u["fh"] != nil }
        let reset = (lastDrop.before + lastDrop.after) / 2
        var start: Double?
        if (after.first?.u["fh"] ?? 0) > 0 {
            start = reset
        } else if let firstUse = after.firstIndex(where: { ($0.u["fh"] ?? 0) > 0 }) {
            start = (after[after.index(before: firstUse)].t + after[firstUse].t) / 2
        }
        // A message on this Mac before the readings noticed any use pins the start exactly.
        if let sent = firstMessage(reset), sent <= (start ?? .infinity) + 10 * 60_000 { start = max(sent, reset) }
        if let start, start + 5 * hour > now { resets["fh"] = start + 5 * hour }
    }
    // Claude's resets land on round times; these are estimates, so round to 10 minutes.
    let tenMinutes = 600_000.0
    return resets.mapValues { ($0 / tenMinutes).rounded() * tenMinutes }
}

/// When the first message after `after` (ms since 1970) was sent in any Claude session on this
/// Mac, from Claude's log ("Sending message to session"), or nil if none in its recent part.
func firstClaudeMessage(after: Double) -> Double? {
    autoreleasepool {
        guard let handle = try? FileHandle(forReadingFrom: claudeLog) else { return nil }
        defer { try? handle.close() }
        let size = handle.seekToEndOfFile()
        handle.seek(toFileOffset: size > 6_000_000 ? size - 6_000_000 : 0)
        let since = logStamp(Date(timeIntervalSince1970: after / 1000))
        for line in String(decoding: handle.readDataToEndOfFile(), as: UTF8.self).split(separator: "\n")
        where line.contains("Sending message to session") && line.prefix(19) >= since {
            return logDate(line.prefix(19)).map { $0.timeIntervalSince1970 * 1000 }
        }
        return nil
    }
}

/// Parses Claude's log time ("2026-11-04 20:31:05", local time).
func logDate(_ stamp: Substring) -> Date? {
    logStampFormat.lock.lock(); defer { logStampFormat.lock.unlock() }
    return logStampFormat.formatter.date(from: String(stamp))
}

// MARK: - Waking a session

/// Whether a session is in the middle of a turn, from Claude's log since Claude started: a turn
/// begins with "Sending message to session X" and ends with "Query completed for session X".
/// ("Mapping internal session X" is not used: Claude also logs it when a session is just opened.)
/// A start without an end only counts while the session file shows activity in the last 2
/// minutes, in case a stopped turn never logged its end.
func turnInProgress(_ id: String) -> Bool {
    guard let launch = claudeApp()?.launchDate,
          let handle = try? FileHandle(forReadingFrom: claudeLog) else { return false }
    defer { try? handle.close() }
    let size = handle.seekToEndOfFile()
    handle.seek(toFileOffset: size > 1_000_000 ? size - 1_000_000 : 0)
    let since = logStamp(launch.addingTimeInterval(-1))
    var running = false
    autoreleasepool {
        for line in String(decoding: handle.readDataToEndOfFile(), as: UTF8.self).split(separator: "\n") where line.contains(id) {
            guard line.prefix(19) >= since else { continue }
            if line.contains("Query completed for session \(id)") { running = false }
            else if line.contains("Sending message to session \(id)") { running = true }
        }
    }
    guard running, let s = session(id) else { return false }
    return Date().timeIntervalSince1970 - s.lastActivity / 1000 < 120
}

/// Waits up to 2 minutes for a session that's in the middle of a turn to finish, so nothing is
/// ever typed into a session while it's replying. False if it's still busy.
func waitForTurnToFinish(_ id: String) -> Bool {
    guard turnInProgress(id) else { return true }
    log("Wake \(id): it's in the middle of a turn; waiting for it to finish")
    let deadline = Date().addingTimeInterval(120)
    while Date() < deadline {
        sleep(3)
        if !turnInProgress(id) {
            log("Wake \(id): its turn finished")
            sleep(2)
            return true
        }
    }
    log("Wake \(id): still busy after 2 minutes; nothing typed")
    return false
}

/// The session Claude's window shows right now, from its log ("setFocusedSession: sessionId=X"
/// since Claude started). nil when none is shown or the log doesn't say.
func shownSessionId() -> String? {
    guard let launch = claudeApp()?.launchDate,
          let handle = try? FileHandle(forReadingFrom: claudeLog) else { return nil }
    defer { try? handle.close() }
    let size = handle.seekToEndOfFile()
    handle.seek(toFileOffset: size > 1_000_000 ? size - 1_000_000 : 0)
    let since = logStamp(launch.addingTimeInterval(-1))
    let marker = "setFocusedSession: sessionId="
    var shown: String?
    autoreleasepool {
        for line in String(decoding: handle.readDataToEndOfFile(), as: UTF8.self).split(separator: "\n") where line.contains(marker) {
            guard line.prefix(19) >= since, let r = line.range(of: marker) else { continue }
            let id = line[r.upperBound...].split(whereSeparator: { $0 == "," || $0 == " " }).first.map(String.init)
            shown = (id == "null") ? nil : id
        }
    }
    return shown
}

/// The text in Claude's focused message box. An empty box reads as "" or a lone newline.
func messageBoxText(_ pid: pid_t) -> String? {
    let app = AXUIElementCreateApplication(pid)
    var focused: CFTypeRef?
    guard AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
          let element = focused else { return nil }
    var value: CFTypeRef?
    AXUIElementCopyAttributeValue(element as! AXUIElement, kAXValueAttribute as CFString, &value)
    return value as? String
}

/// Waits (up to `seconds`) until nobody has touched the Mac for `quiet` seconds.
func waitUntilIdle(quiet: Double, seconds: Double) -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while secondsSinceInput() < quiet {
        guard Date() < deadline else { return false }
        sleep(1)
    }
    return true
}

/// Clears Claude's focused message box (⌘A, Delete).
func clearMessageBox(_ pid: pid_t) {
    let source = CGEventSource(stateID: .hidSystemState)
    for (key, flags) in [(CGKeyCode(0), CGEventFlags.maskCommand), (CGKeyCode(51), CGEventFlags())] {
        for down in [true, false] {
            let event = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: down)
            event?.flags = flags
            event?.postToPid(pid)
        }
        usleep(150_000)
    }
    usleep(300_000)
}

/// Text Remote Keeper itself may have left in a message box (its command, which Claude's command
/// menu can leave without the slash, or its wake message). Anything else belongs to the person.
func isOwnLeftover(_ text: String) -> Bool {
    let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
    return t == "remote-control" || t == remoteControlCommand || t == wakeText
}

/// Checked right before anything is typed: Claude shows this session, its message box is empty,
/// and nobody is using the Mac. Typing goes to whatever box has focus, so without these a wake
/// could land in another session, or be mixed into what someone is typing.
func readyToType(_ id: String, pid: pid_t) -> WakeError? {
    if turnInProgress(id) {
        log("Wake \(id): a turn started; nothing typed")
        return .busy
    }
    guard waitUntilIdle(quiet: 5, seconds: 30) else {
        log("Wake \(id): someone is using the Mac; nothing typed")
        return .userActive
    }
    let shown = shownSessionId()
    guard shown == id else {
        log("Wake \(id): Claude is showing \(shown ?? "no session"), not this one; nothing typed")
        return .wrongSession
    }
    if let text = messageBoxText(pid), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        if isOwnLeftover(text) {
            clearMessageBox(pid)
            log("Wake \(id): cleared text Remote Keeper had left in its message box")
            if let after = messageBoxText(pid), after.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return nil }
        }
        log("Wake \(id): its message box has unsent text; nothing typed")
        return .draft
    }
    return nil
}

enum WakeError: Error, CustomStringConvertible {
    case noAccessibility, locked, noSession, claudeNotRunning, noMessageBox, noReply, busy, wrongSession, draft, userActive

    var description: String {
        switch self {
        case .noAccessibility: return "Remote Keeper needs permission to type. Open Remote Keeper on your computer and turn on Allow Typing."
        case .locked: return "your Mac is locked, so nothing was typed. Unlock it and try again."
        case .noSession: return "that session is gone (archived, or its folder moved)."
        case .claudeNotRunning: return "the Claude app didn't open."
        case .noMessageBox: return "Claude's message box didn't get focus, so nothing was typed."
        case .noReply: return "Remote Control didn't come back on. Check the session in the Claude app."
        case .busy: return "it's still working on a reply, so nothing was typed. Tap Reconnect again once it's done."
        case .wrongSession: return "Claude didn't switch to that session, so nothing was typed. Tap Reconnect to try again."
        case .draft: return "there's unsent text in that session's message box, so nothing was typed. Send or clear it, then tap Reconnect."
        case .userActive: return "someone is using the Mac right now, so nothing was typed. Tap Reconnect again in a moment."
        }
    }

    /// Claude wasn't ready yet; trying again a little later usually works.
    var worthRetrying: Bool {
        switch self {
        case .noMessageBox, .wrongSession: return true
        default: return false
        }
    }
}

// MARK: - Claude's own updates

/// The Claude app's version, from its bundle.
func claudeVersion() -> String? {
    guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: claudeBundleID) else { return nil }
    return Bundle(url: url)?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
}

/// The update Claude installed when it last started, from its log ("[updater] Version changed
/// since last launch: 1.2.3 → 1.2.4"), or nil if this launch wasn't an update.
func claudeInstalledUpdate() -> (from: String, to: String)? {
    autoreleasepool {
        guard let launch = claudeApp()?.launchDate,
              let handle = try? FileHandle(forReadingFrom: claudeLog) else { return nil }
        defer { try? handle.close() }
        let size = handle.seekToEndOfFile()
        handle.seek(toFileOffset: size > 6_000_000 ? size - 6_000_000 : 0)
        let since = logStamp(launch.addingTimeInterval(-5))
        var found: (String, String)?
        for line in String(decoding: handle.readDataToEndOfFile(), as: UTF8.self).split(separator: "\n")
        where line.contains("[updater] Version changed since last launch: ") && line.prefix(19) >= since {
            let parts = line.components(separatedBy: "since last launch: ").last?.components(separatedBy: " → ") ?? []
            if parts.count == 2 {
                let from = parts[0].trimmingCharacters(in: .whitespaces), to = parts[1].trimmingCharacters(in: .whitespaces)
                if from.count < 40, to.count < 40 { found = (from, to) }
            }
        }
        return found
    }
}

/// The newest Claude Code engine the Claude app has downloaded (it keeps them in
/// ~/Library/Application Support/Claude/claude-code/<version>), which new sessions use.
func claudeCodeVersion() -> String? {
    let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Claude/claude-code")
    let versions = ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [])
        .filter { $0.split(separator: ".").count == 3 && $0.allSatisfy { $0.isNumber || $0 == "." } }
    return versions.max { a, b in
        let x = a.split(separator: ".").map { Int($0) ?? 0 }, y = b.split(separator: ".").map { Int($0) ?? 0 }
        return x.lexicographicallyPrecedes(y)
    }
}

/// A Claude update that has downloaded and installs the next time Claude quits, from Claude's log
/// since it started ("[updater] Update downloaded and ready to install { releaseName: 'Claude 1.2.3' }").
/// nil when there's none, or it's the version already running.
func claudeUpdateReady() -> String? {
    autoreleasepool {
        guard let launch = claudeApp()?.launchDate,
              let handle = try? FileHandle(forReadingFrom: claudeLog) else { return nil }
        defer { try? handle.close() }
        let size = handle.seekToEndOfFile()
        handle.seek(toFileOffset: size > 6_000_000 ? size - 6_000_000 : 0)
        let since = logStamp(launch)
        var ready: String?
        for line in String(decoding: handle.readDataToEndOfFile(), as: UTF8.self).split(separator: "\n")
        where line.contains("[updater] Update downloaded and ready to install") && line.prefix(19) >= since {
            if let r = line.range(of: "releaseName: '") {
                let rest = line[r.upperBound...]
                let name = rest.prefix { $0 != "'" }
                let version = name.split(separator: " ").last.map(String.init) ?? String(name)
                if !version.isEmpty, version.count < 40 { ready = version }
            }
        }
        guard let ready, ready != claudeVersion() else { return nil }
        return ready
    }
}

// MARK: - Claude's usage popup (exact reset times)

/// What Claude's usage popup (the button under the message box) showed: each limit's name, percent
/// used and exact reset time ("Resets at 10:40 PM", "Resets Wed 6:00 PM"). The menu-bar menu only
/// shows rounded times ("Resets 2h"), so these fix the estimates.
struct PopupUsage: Codable {
    struct Row: Codable { let label: String; let percent: Double; let resetAt: Double? }  // ms since 1970
    let at: Double
    let rows: [Row]

    static var latest: PopupUsage? = load() {
        didSet {
            guard let latest, let data = try? JSONEncoder().encode(latest) else { return }
            try? FileManager.default.createDirectory(at: supportDir, withIntermediateDirectories: true)
            try? data.write(to: file, options: .atomic)
        }
    }
    private static let file = supportDir.appendingPathComponent("claude-usage-popup.json")
    private static func load() -> PopupUsage? { (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode(PopupUsage.self, from: $0) } }

    /// Whether it's worth opening the popup again: no reading, an old one, or a reset has passed.
    static var stale: Bool {
        guard let latest else { return true }
        let now = Date().timeIntervalSince1970 * 1000
        return now - latest.at > 60 * 60_000 || latest.rows.contains { ($0.resetAt ?? .infinity) < now }
    }

    /// "Resets at 10:40 PM", "Resets Wed 6:00 PM", "Resets Nov 12 at 6:00 PM", "Resets in 3 hr 20 min".
    static func parseReset(_ text: String, now: Date = Date()) -> Double? {
        var t = text.trimmingCharacters(in: .whitespaces)
        for prefix in ["Resets", "at ", "in "] where t.lowercased().hasPrefix(prefix.lowercased()) {
            t = String(t.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
        }
        let cal = Calendar.current
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        func ms(_ d: Date) -> Double { d.timeIntervalSince1970 * 1000 }
        for format in ["h:mm a", "h a", "H:mm"] {
            f.dateFormat = format
            if let time = f.date(from: t) {
                let c = cal.dateComponents([.hour, .minute], from: time)
                guard var d = cal.date(bySettingHour: c.hour ?? 0, minute: c.minute ?? 0, second: 0, of: now) else { continue }
                if d <= now { d = cal.date(byAdding: .day, value: 1, to: d) ?? d }
                return ms(d)
            }
        }
        let days = ["sun", "mon", "tue", "wed", "thu", "fri", "sat"]
        let parts = t.split(separator: " ", maxSplits: 1).map(String.init)
        if parts.count == 2, let day = days.firstIndex(where: { parts[0].lowercased().hasPrefix($0) }) {
            var rest = parts[1]
            if rest.lowercased().hasPrefix("at ") { rest = String(rest.dropFirst(3)) }
            for format in ["h:mm a", "h a", "H:mm"] {
                f.dateFormat = format
                if let time = f.date(from: rest) {
                    let c = cal.dateComponents([.hour, .minute], from: time)
                    if let d = cal.nextDate(after: now, matching: DateComponents(hour: c.hour, minute: c.minute, weekday: day + 1), matchingPolicy: .nextTime) { return ms(d) }
                }
            }
        }
        f.dateFormat = "MMM d h:mm a"
        if let d = f.date(from: t.replacingOccurrences(of: " at ", with: " ")) {
            var c = cal.dateComponents([.month, .day, .hour, .minute], from: d); c.year = cal.component(.year, from: now)
            if let date = cal.date(from: c) { return ms(date < now.addingTimeInterval(-86_400) ? cal.date(byAdding: .year, value: 1, to: date) ?? date : date) }
        }
        var total = 0.0
        let scanner = Scanner(string: t.lowercased())
        while !scanner.isAtEnd {
            guard let n = scanner.scanDouble() else { _ = scanner.scanCharacter(); continue }
            let unit = scanner.scanCharacters(from: .letters) ?? ""
            total += n * (unit.hasPrefix("d") ? 86_400_000 : unit.hasPrefix("h") ? 3_600_000 : unit.hasPrefix("m") ? 60_000 : 0)
        }
        return total > 0 ? ms(now) + total : nil
    }

    /// Opens Claude's usage popup through Accessibility (a press on its button; nothing typed),
    /// reads it, closes it, and puts the keyboard focus back. Only when the reading is stale (or
    /// `force`), nobody has touched the Mac for a minute and the screen isn't locked.
    @discardableResult
    static func refresh(force: Bool = false) -> Bool {
        guard let claude = claudeApp(), !screenLocked() else { return false }
        if !force { guard stale, secondsSinceInput() >= 60 else { return false } }
        let pid = claude.processIdentifier
        func string(_ e: AXUIElement, _ a: String) -> String? {
            var v: CFTypeRef?; AXUIElementCopyAttributeValue(e, a as CFString, &v); return (v as? String).flatMap { $0.isEmpty ? nil : $0 }
        }
        func walk(_ e: AXUIElement, _ depth: Int, _ visit: (AXUIElement) -> Bool) -> Bool {
            guard depth < 60 else { return false }
            if visit(e) { return true }
            for child in axChildren(e) ?? [] where walk(child, depth + 1, visit) { return true }
            return false
        }
        var button: AXUIElement?
        for window in claudeWindows(pid) where button == nil {
            _ = walk(window, 0) { e in
                if string(e, kAXRoleAttribute) == "AXPopUpButton", (string(e, kAXDescriptionAttribute) ?? "").hasPrefix("Usage:") { button = e; return true }
                return false
            }
        }
        guard let button else { return false }
        let app = AXUIElementCreateApplication(pid)
        var focused: CFTypeRef?
        AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &focused)
        guard AXUIElementPerformAction(button, kAXPressAction as CFString) == .success else { return false }
        defer {
            AXUIElementPerformAction(button, kAXPressAction as CFString)
            usleep(200_000)
            if let focused { AXUIElementSetAttributeValue(focused as! AXUIElement, kAXFocusedAttribute as CFString, kCFBooleanTrue) }
        }
        // The popup's rows, in order: the limit's name, "Resets …", then its level indicator.
        var rows: [Row] = []
        _ = poll(seconds: 2, every: 0.2) {
            rows = []
            var resets: [String] = []
            for window in claudeWindows(pid) {
                _ = walk(window, 0) { e in
                    let role = string(e, kAXRoleAttribute)
                    if role == "AXStaticText", let text = string(e, kAXValueAttribute) ?? string(e, kAXTitleAttribute), text.lowercased().hasPrefix("resets") { resets.append(text) }
                    if role == "AXLevelIndicator" || role == "AXProgressIndicator", let label = string(e, kAXDescriptionAttribute) ?? string(e, kAXTitleAttribute) {
                        var v: CFTypeRef?; AXUIElementCopyAttributeValue(e, kAXValueAttribute as CFString, &v)
                        let percent = (v as? NSNumber)?.doubleValue ?? 0
                        rows.append(Row(label: label, percent: percent, resetAt: resets.last.flatMap { parseReset($0) }))
                        resets = []
                    }
                    return false
                }
            }
            return !rows.isEmpty
        }
        guard !rows.isEmpty else { log("Couldn't read Claude's usage popup"); return false }
        latest = PopupUsage(at: Date().timeIntervalSince1970 * 1000, rows: rows)
        log("Claude's usage popup: " + rows.map { "\($0.label) \(Int($0.percent))%" + ($0.resetAt.map { " resets \(Date(timeIntervalSince1970: $0 / 1000))" } ?? "") }.joined(separator: ", "))
        return true
    }
}

// MARK: - Fresh usage readings

/// How old Claude's newest usage reading is, in seconds (nil without one).
func planUsageAge() -> Double? {
    guard let data = try? Data(contentsOf: planUsageFile),
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let t = (json["samples"] as? [[String: Any]])?.last?["t"] as? Double else { return nil }
    return Date().timeIntervalSince1970 - t / 1000
}

private var lastUsageNudge = Date.distantPast

/// Claude checks plan usage on its own only while someone is using the Mac (it skips its check
/// after 10 idle minutes, and stops entirely a day after its menu-bar icon was last opened), so a
/// phone away from the Mac sees an old reading. Right-clicking Claude's menu-bar icon makes Claude
/// fetch usage right away (and restarts its own checks); this does exactly that, then closes the
/// menu. Only when the reading is over 10 minutes old, nobody has touched the Mac for a minute,
/// the screen isn't locked, and at most every 5 minutes. Escape is pressed only if Claude's menu
/// really opened, so it can never reach a Claude window (where it would stop a reply). Returns
/// whether it clicked; Claude saves the new reading a moment later, which the usage watcher sends.
@discardableResult
func nudgeClaudeUsage(force: Bool = false) -> Bool {
    guard let claude = claudeApp(), !screenLocked() else { return false }
    if !force {
        let menuAge = TrayUsage.latest.map { Date().timeIntervalSince1970 - $0.at / 1000 } ?? .infinity
        guard (planUsageAge() ?? .infinity) > 10 * 60 || menuAge > 60 * 60, secondsSinceInput() >= 60,
              Date().timeIntervalSince(lastUsageNudge) > 5 * 60 else { return false }
    }
    let app = AXUIElementCreateApplication(claude.processIdentifier)
    var bar: CFTypeRef?
    guard AXUIElementCopyAttributeValue(app, "AXExtrasMenuBar" as CFString, &bar) == .success, let bar,
          let items = axChildren(bar as! AXUIElement), let item = items.first,
          let origin = axPoint(item, kAXPositionAttribute), let size = axSize(item) else { return false }
    lastUsageNudge = Date()
    let target = CGPoint(x: origin.x + size.width / 2, y: origin.y + size.height / 2)
    let cursor = CGEvent(source: nil)?.location
    let pid = claude.processIdentifier
    let menusBefore = popUpMenus(of: pid)
    let source = CGEventSource(stateID: .hidSystemState)
    CGEvent(mouseEventSource: source, mouseType: .rightMouseDown, mouseCursorPosition: target, mouseButton: .right)?.post(tap: .cghidEventTap)
    usleep(50_000)
    CGEvent(mouseEventSource: source, mouseType: .rightMouseUp, mouseCursorPosition: target, mouseButton: .right)?.post(tap: .cghidEventTap)
    // Claude's menu is a pop-up menu window of its own; wait for it, then close it with Escape.
    let opened = poll(seconds: 2, every: 0.1) { popUpMenus(of: pid) > menusBefore }
    if opened {
        usleep(400_000)
        // The menu shows each limit with a rounded reset ("6% · Resets 4h"): read it for the
        // exact reset times (see TrayUsage) before closing it.
        if let reading = TrayUsage.read(pid: pid) {
            TrayUsage.latest = reading
            log("Claude's menu: " + reading.rows.map { "\($0.label) \(Int($0.percent))%" + ($0.resetIn.map { " resets in \(Int($0 / 60_000))m" } ?? "") }.joined(separator: ", "))
        } else {
            log("Couldn't read the usage in Claude's menu")
        }
        CGEvent(keyboardEventSource: source, virtualKey: 53, keyDown: true)?.post(tap: .cghidEventTap)
        CGEvent(keyboardEventSource: source, virtualKey: 53, keyDown: false)?.post(tap: .cghidEventTap)
        _ = poll(seconds: 1, every: 0.1) { popUpMenus(of: pid) <= menusBefore }
    }
    if let cursor { CGWarpMouseCursorPosition(cursor) }
    log("Asked Claude for fresh usage (menu \(opened ? "opened and closed" : "didn't open"))")
    return true
}

/// What Claude's menu-bar menu showed: each limit's name, percent used and rounded time to reset
/// ("Resets 4h", "Resets 6d", "Resets 45m"). Claude keeps the exact reset times only in memory,
/// so the rounded ones pin down which estimate is right (and add limits the usage file leaves
/// out, like "Weekly · Fable").
struct TrayUsage: Codable {
    struct Row: Codable { let label: String; let percent: Double; let resetIn: Double?; let unit: Double }  // ms
    let at: Double  // ms since 1970
    let rows: [Row]

    /// The newest reading. Saved to disk so a restart of Remote Keeper (an update, say) doesn't
    /// lose the reset times until the next time the menu can be read.
    static var latest: TrayUsage? = load() {
        didSet {
            guard let latest, let data = try? JSONEncoder().encode(latest) else { return }
            try? FileManager.default.createDirectory(at: supportDir, withIntermediateDirectories: true)
            try? data.write(to: file, options: .atomic)
        }
    }
    private static let file = supportDir.appendingPathComponent("claude-menu-usage.json")
    private static func load() -> TrayUsage? {
        (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode(TrayUsage.self, from: $0) }
    }

    /// The keys the usage file uses for the rows it has.
    static let keys = ["5-hour limit": "fh", "Weekly · all models": "sd", "Weekly · Opus": "so", "Weekly · Sonnet": "sn"]

    /// Reads the open menu through Accessibility: its window is found by position (the menu
    /// isn't in Claude's usual accessibility tree).
    static func read(pid: pid_t) -> TrayUsage? {
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
        guard let window = windows.first(where: { ($0[kCGWindowOwnerPID as String] as? Int) == Int(pid) && ($0[kCGWindowLayer as String] as? Int) == 101 }),
              let b = window[kCGWindowBounds as String] as? [String: Double],
              let x = b["X"], let y = b["Y"], let w = b["Width"], let h = b["Height"] else { return nil }
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(AXUIElementCreateSystemWide(), Float(x + w / 2), Float(y + min(12, h / 2)), &hit) == .success,
              var element = hit else { return nil }
        for _ in 0..<6 where axString(element, kAXRoleAttribute) != "AXMenu" {
            var parent: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, kAXParentAttribute as CFString, &parent) == .success, let parent else { return nil }
            element = parent as! AXUIElement
        }
        guard axString(element, kAXRoleAttribute) == "AXMenu" else { return nil }
        var rows: [Row] = []
        for item in axChildren(element) ?? [] {
            let texts = (axChildren(item) ?? []).flatMap { axChildren($0) ?? [] }
                .filter { axString($0, kAXRoleAttribute) == "AXStaticText" }
                .compactMap { axString($0, kAXValueAttribute) ?? axString($0, kAXTitleAttribute) ?? axString($0, kAXDescriptionAttribute) }
            guard texts.count >= 2, let row = parse(label: texts[0], detail: texts[1]) else { continue }
            rows.append(row)
        }
        return rows.isEmpty ? nil : TrayUsage(at: Date().timeIntervalSince1970 * 1000, rows: rows)
    }

    /// "6% · Resets 4h" (also "Resets 1h 20m", "Resets 45m", "Resets 6d").
    static func parse(label: String, detail: String) -> Row? {
        let parts = detail.components(separatedBy: "·").map { $0.trimmingCharacters(in: .whitespaces) }
        guard let percent = parts.first.flatMap({ Double($0.replacingOccurrences(of: "%", with: "")) }) else { return nil }
        var total = 0.0, unit = 0.0
        if let resets = parts.dropFirst().first(where: { $0.lowercased().hasPrefix("resets") }) {
            let scanner = Scanner(string: resets.lowercased().replacingOccurrences(of: "resets", with: "").replacingOccurrences(of: "in", with: ""))
            while !scanner.isAtEnd {
                guard let n = scanner.scanDouble() else { _ = scanner.scanCharacter(); continue }
                let letters = scanner.scanCharacters(from: .letters) ?? ""
                let size: Double = letters.hasPrefix("d") ? 86_400_000 : letters.hasPrefix("h") ? 3_600_000 : letters.hasPrefix("m") ? 60_000 : 0
                guard size > 0 else { continue }
                total += n * size
                unit = unit == 0 ? size : min(unit, size)
            }
        }
        return Row(label: label, percent: percent, resetIn: unit > 0 ? total : nil, unit: unit)
    }

    /// Fixes the estimated resets so they agree with what the menu showed, and adds limits the
    /// usage file doesn't have (with their names). The menu's time may be rounded either way, so
    /// a reset fits if it lands from half a unit before to a whole unit after.
    func correct(_ resets: inout [String: Double], limits: inout [String: Double], labels: inout [String: String],
                 now: Double, firstMessage: (Double) -> Double?) {
        let hour = 3_600_000.0, tenMinutes = 600_000.0
        for (i, row) in rows.enumerated() {
            let key = Self.keys[row.label] ?? "m\(i)"
            if Self.keys[row.label] == nil { labels[key] = row.label; limits[key] = row.percent }
            guard let resetIn = row.resetIn else { continue }
            let low = at + resetIn - row.unit / 2, high = at + resetIn + row.unit
            guard high > now else { continue }   // that reset has passed since the menu was read
            if let estimate = resets[key], estimate >= low, estimate <= high { continue }
            var fixed: Double?
            if key == "fh" {
                // The 5-hour window began with the first message sent 5 hours before the reset.
                if let sent = firstMessage(low - 5 * hour), sent <= high - 5 * hour { fixed = sent + 5 * hour }
            } else if let weekly = resets["sd"], weekly >= low, weekly <= high {
                fixed = weekly   // other weekly limits reset with the all-models one
            }
            resets[key] = ((fixed ?? (low + high) / 2) / tenMinutes).rounded() * tenMinutes
        }
    }
}

private func axString(_ element: AXUIElement, _ attribute: String) -> String? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
    return (value as? String).flatMap { $0.isEmpty ? nil : $0 }
}

/// On-screen pop-up menu windows (level 101) that belong to `pid`.
private func popUpMenus(of pid: pid_t) -> Int {
    let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
    return windows.filter { ($0[kCGWindowOwnerPID as String] as? Int) == Int(pid) && ($0[kCGWindowLayer as String] as? Int) == 101 }.count
}

private func axChildren(_ element: AXUIElement) -> [AXUIElement]? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value) == .success else { return nil }
    return value as? [AXUIElement]
}

private func axPoint(_ element: AXUIElement, _ attribute: String) -> CGPoint? {
    var value: CFTypeRef?
    var point = CGPoint.zero
    guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success, let value,
          AXValueGetValue(value as! AXValue, .cgPoint, &point) else { return nil }
    return point
}

private func axSize(_ element: AXUIElement) -> CGSize? {
    var value: CFTypeRef?
    var size = CGSize.zero
    guard AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &value) == .success, let value,
          AXValueGetValue(value as! AXValue, .cgSize, &size) else { return nil }
    return size
}

func screenLocked() -> Bool {
    guard let d = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
    return (d["CGSSessionScreenIsLocked"] as? Int ?? 0) == 1 || d["CGSSessionScreenIsLocked"] as? Bool == true
}

func secondsSinceInput() -> Double {
    [CGEventType.keyDown, .mouseMoved, .leftMouseDown, .scrollWheel]
        .map { CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: $0) }
        .min() ?? 999
}

/// Brings Claude to the front through Launch Services, which works from a background app (a
/// plain activate() is often ignored on macOS 14 and later unless the caller is in front).
func bringClaudeForward(opening url: URL? = nil) {
    guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: claudeBundleID) else { return }
    let configuration = NSWorkspace.OpenConfiguration()
    configuration.activates = true
    let done = DispatchSemaphore(value: 0)
    if let url {
        NSWorkspace.shared.open([url], withApplicationAt: appURL, configuration: configuration) { _, _ in done.signal() }
    } else {
        NSWorkspace.shared.openApplication(at: appURL, configuration: configuration) { _, _ in done.signal() }
    }
    _ = done.wait(timeout: .now() + 10)
    claudeApp()?.activate()
}

/// Claude's windows, the focused and main ones first.
func claudeWindows(_ pid: pid_t) -> [AXUIElement] {
    let app = AXUIElementCreateApplication(pid)
    AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
    var list: [AXUIElement] = []
    for attribute in [kAXFocusedWindowAttribute, kAXMainWindowAttribute] {
        var value: CFTypeRef?
        if AXUIElementCopyAttributeValue(app, attribute as CFString, &value) == .success, let value {
            let window = value as! AXUIElement
            if !list.contains(where: { CFEqual($0, window) }) { list.append(window) }
        }
    }
    var all: CFTypeRef?
    if AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &all) == .success, let windows = all as? [AXUIElement] {
        for window in windows where !list.contains(where: { CFEqual($0, window) }) { list.append(window) }
    }
    return list
}

/// Claude 4.23 and later show each session's own Remote Control switch next to its message box.
/// Returns it, from the front window first (that's where the session was just opened).
func remoteControlSwitch(_ pid: pid_t) -> AXUIElement? {
    var found: AXUIElement?
    func walk(_ element: AXUIElement, depth: Int) {
        guard depth < 60, found == nil else { return }
        var subrole: CFTypeRef?, title: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &subrole)
        if subrole as? String == "AXSwitch" {
            AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &title)
            if title as? String == "Remote Control" { found = element; return }
        }
        var kids: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &kids) == .success,
              let children = kids as? [AXUIElement] else { return }
        for child in children { walk(child, depth: depth + 1) }
    }
    for window in claudeWindows(pid) where found == nil { walk(window, depth: 0) }
    return found
}

/// Turns Remote Control on with the session's own switch (Claude 4.23 and later), so nothing is
/// typed. Only for sessions Claude is running: one it hasn't started refuses ("no active query"),
/// and the wake message is the fast way for those. nil when the switch isn't there (older
/// Claude) or Claude didn't take it, so the caller types instead, right away.
func pressRemoteControlSwitch(_ id: String, pid: pid_t, wait seconds: Double) -> Bool? {
    var toggle: AXUIElement?
    guard poll(seconds: seconds, every: 0.2, { toggle = remoteControlSwitch(pid); return toggle != nil }), let toggle else {
        log("Wake \(id): no Remote Control switch in Claude's window; typing instead")
        return nil
    }
    var value: CFTypeRef?
    AXUIElementCopyAttributeValue(toggle, kAXValueAttribute as CFString, &value)
    // On already but Claude doesn't say so yet: pressing it would switch it off.
    guard (value as? NSNumber)?.intValue == 0, shownSessionId() == id else { return nil }
    let since = Date()
    guard AXUIElementPerformAction(toggle, kAXPressAction as CFString) == .success else { return nil }
    // Claude logs right away whether it took it ("Enabling remote control for session …") or not
    // ("Cannot toggle remote control for … : no active query").
    var refused = false
    let enabling = poll(seconds: 5, every: 0.1) {
        let lines = claudeLogLines(since: since, about: id)
        refused = lines.contains { $0.contains("Cannot toggle remote control for \(id)") }
        return refused || lines.contains { $0.contains("Enabling remote control for session \(id)") }
    } && !refused
    log("Wake \(id): pressed its Remote Control switch (\(enabling ? "Claude is turning it on" : refused ? "Claude refused: not running yet" : "no answer"))")
    return enabling ? true : nil
}


/// Finds the session's message box in Claude's front window and gives it focus.
func focusMessageBox(_ pid: pid_t) -> Bool {
    if messageBoxFocused(pid) { return true }
    let windows = claudeWindows(pid)
    guard !windows.isEmpty else {
        log("Focus: Claude has no window")
        return false
    }
    // The message box is an editable text area; there's normally one, at the bottom.
    var boxes: [(AXUIElement, CGFloat)] = []
    func walk(_ element: AXUIElement, depth: Int) {
        guard depth < 60, boxes.count < 20 else { return }
        var role: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role)
        if role as? String == "AXTextArea" {
            var position: CFTypeRef?
            var point = CGPoint.zero
            if AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &position) == .success, let position {
                AXValueGetValue(position as! AXValue, .cgPoint, &point)
            }
            boxes.append((element, point.y))
        }
        var kids: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &kids) == .success,
              let children = kids as? [AXUIElement] else { return }
        for child in children { walk(child, depth: depth + 1) }
    }
    // The front window first; another one only if it has no message box (right after an update
    // the window Claude reports as focused isn't always the one showing the session).
    for root in windows where boxes.isEmpty { walk(root, depth: 0) }
    guard let box = boxes.max(by: { $0.1 < $1.1 })?.0 else {
        log("Focus: no message box found in Claude's \(windows.count == 1 ? "window" : "\(windows.count) windows")")
        return false
    }
    AXUIElementSetAttributeValue(box, kAXFocusedAttribute as CFString, kCFBooleanTrue)
    usleep(300_000)
    let ok = messageBoxFocused(pid)
    log("Focus: set focus on the message box (\(ok ? "ok" : "still not focused"))")
    return ok
}

/// True when Claude's focused element is a text box (the session's message box).
func messageBoxFocused(_ pid: pid_t) -> Bool {
    let app = AXUIElementCreateApplication(pid)
    AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
    var focused: CFTypeRef?
    guard AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
          let element = focused else { return false }
    var role: CFTypeRef?
    AXUIElementCopyAttributeValue(element as! AXUIElement, kAXRoleAttribute as CFString, &role)
    return ["AXTextArea", "AXTextField"].contains(role as? String ?? "")
}

/// Types into the Claude process only (posted to its pid, so a window that steals focus never
/// receives it), then presses Return.
func type(_ text: String, into pid: pid_t, pressReturn: Bool = true) {
    let source = CGEventSource(stateID: .hidSystemState)
    let units = Array(text.utf16)
    var index = 0
    while index < units.count {
        let chunk = Array(units[index..<min(index + 16, units.count)])
        for down in [true, false] {
            let event = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: down)
            event?.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: chunk)
            event?.postToPid(pid)
        }
        index += 16
        usleep(15_000)
    }
    guard pressReturn else { return }
    usleep(300_000)
    for down in [true, false] {
        CGEvent(keyboardEventSource: source, virtualKey: 36, keyDown: down)?.postToPid(pid)
    }
}

/// Presses one key (by key code) in the Claude process.
func pressKey(_ key: CGKeyCode, _ pid: pid_t) {
    let source = CGEventSource(stateID: .hidSystemState)
    for down in [true, false] {
        CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: down)?.postToPid(pid)
    }
}

/// Presses Return in the Claude process.
func pressReturn(_ pid: pid_t) {
    let source = CGEventSource(stateID: .hidSystemState)
    for down in [true, false] {
        CGEvent(keyboardEventSource: source, virtualKey: 36, keyDown: down)?.postToPid(pid)
    }
}

/// What a reconnect did. `pendingSince` is set when the wake message went out and Claude is
/// reconnecting the session on its own; the caller confirms that from Claude's log later.
struct WakeDone: ExpressibleByStringInterpolation {
    let text: String
    var pendingSince: Date? = nil

    init(text: String, pendingSince: Date? = nil) { self.text = text; self.pendingSince = pendingSince }
    init(stringLiteral value: String) { text = value }
    init(stringInterpolation: DefaultStringInterpolation) { text = String(stringInterpolation: stringInterpolation) }
}

/// Reconnects one session. With `verifyLater`, a session that only needs Claude to resume it is
/// left reconnecting by itself (about a second) while the caller moves on to the next one.
func wake(_ id: String, dryRun: Bool = false, verifyLater: Bool = false) -> Result<WakeDone, WakeError> {
    guard let target = session(id), !target.archived, FileManager.default.fileExists(atPath: target.cwd) else { return .failure(.noSession) }
    if RemoteControlStatus.now().isOn(target) { return .success("\(target.title): Remote Control is already on.") }
    if dryRun { return .success("Would reconnect \(target.title) (\(id))") }
    guard AXIsProcessTrusted() else { return .failure(.noAccessibility) }
    guard !screenLocked() else { return .failure(.locked) }

    // Never type into a session that's replying: wait for its turn to end. Finishing a turn
    // often reconnects it by itself.
    guard waitForTurnToFinish(id) else { return .failure(.busy) }
    if RemoteControlStatus.now().isOn(session(id) ?? target) { return .success("\(target.title): Remote Control is back on.") }

    // Give someone using the Mac a moment to pause, so the switch to Claude isn't a surprise.
    _ = waitUntilIdle(quiet: 8, seconds: 30)

    if claudeApp() == nil {
        bringClaudeForward()
        for _ in 0..<30 where claudeApp() == nil { sleep(1) }
        guard claudeApp() != nil else { return .failure(.claudeNotRunning) }
        sleep(12)   // let it load its sessions
    }
    guard let app = claudeApp() else { return .failure(.claudeNotRunning) }
    // Right after Claude starts, its window isn't ready for a while.
    let sinceLaunch = app.launchDate.map { Date().timeIntervalSince($0) } ?? 999
    if sinceLaunch < 60 { sleep(UInt32(60 - sinceLaunch)) }

    // Open the session and make sure Claude actually switched to it (checked 5 times a second).
    let link = URL(string: "claude://claude.ai/epitaxy/\(id)")!
    var switched = false
    for attempt in 0..<2 where !switched {
        bringClaudeForward(opening: link)
        switched = poll(seconds: 8) { shownSessionId() == id }
        if !switched { log("Wake \(id): Claude didn't switch to it (attempt \(attempt + 1))") }
    }
    guard switched else { return .failure(.wrongSession) }
    let pid = app.processIdentifier
    // 0. A session Claude is running, on Claude 4.23 and later: its own Remote Control switch.
    //    Nothing typed. (Sessions Claude hasn't started can't take it; the wake message below is
    //    the fast way for those.)
    if sessionStarted(id), pressRemoteControlSwitch(id, pid: pid, wait: 2) == true {
        return .success("\(target.title): Remote Control is back on.")
    }
    // A session Claude only just loaded can take a while to show its message box.
    var tries = 0
    let focused = poll(seconds: sinceLaunch < 180 ? 15 : 5, every: 0.25) {
        tries += 1
        if tries == 12 { bringClaudeForward() }
        return focusMessageBox(pid)
    }
    guard focused else {
        let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "none"
        log("Wake \(id): no message box focus (front app: \(front), Claude active: \(app.isActive))")
        return .failure(.noMessageBox)
    }
    // Check again right before typing: a turn may have started meanwhile, and /remote-control
    // switches Remote Control off if it's already on.
    if turnInProgress(id) {
        guard waitForTurnToFinish(id) else { return .failure(.busy) }
        guard focusMessageBox(pid) else { return .failure(.noMessageBox) }
    }
    if RemoteControlStatus.now().isOn(session(id) ?? target) { return .success("\(target.title): Remote Control is already on.") }

    // 1. A session Claude is running: its own /remote-control command (no Claude usage; also
    //    works when the session's switch was turned off). Sessions Claude hasn't started since it
    //    launched can't take it ("no active query"), so they skip straight to step 2.
    if sessionStarted(id) {
        if let problem = readyToType(id, pid: pid) { return .failure(problem) }
        switch runRemoteControlCommand(id, pid: pid, since: Date()) {
        case .on:
            return .success("\(target.title): Remote Control is back on.")
        case .switchedOff:
            // It was on after all and the command switched it off: switch it back on.
            log("/remote-control switched \(id) off; switching it back on")
            if let problem = readyToType(id, pid: pid) { return .failure(problem) }
            return runRemoteControlCommand(id, pid: pid, since: Date()) == .on
                ? .success("\(target.title): Remote Control is on.") : .failure(.noReply)
        case .notRunning, .nothing:
            guard focusMessageBox(pid) else { return .failure(.noMessageBox) }
        }
    }

    // 2. One short message starts the session, and Claude turns Remote Control back on by itself
    //    as it resumes ("cold resume"), about a second later. No need to wait for the reply.
    //    A session whose own switch is off doesn't reconnect by itself: once it's resumed,
    //    /remote-control works.
    if let problem = readyToType(id, pid: pid) { return .failure(problem) }
    let switchedOff = (session(id) ?? target).userEnabled == false
    let sent = Date()
    type(wakeText, into: pid)
    log("Sent the wake message to \(id) to start it")
    if verifyLater && !switchedOff {
        return .success(WakeDone(text: "\(target.title): reconnecting", pendingSince: sent))
    }
    var resumed = false
    let on = poll(seconds: 20) {
        let lines = claudeLogLines(since: sent, about: id)
        resumed = resumed || lines.contains { $0.contains("Mapping internal session \(id)") || $0.contains("Resuming session \(id)") }
        return lines.contains { $0.contains("Enabling remote control for session \(id)") } || (switchedOff && resumed)
    }
    if on && !switchedOff { return .success("\(target.title): Remote Control is back on.") }
    guard resumed else { return .failure(.noReply) }
    // It started but didn't reconnect by itself (its switch is off): now /remote-control works.
    guard waitForTurnToFinish(id), focusMessageBox(pid) else { return .failure(.noMessageBox) }
    if let problem = readyToType(id, pid: pid) { return .failure(problem) }
    return runRemoteControlCommand(id, pid: pid, since: Date()) == .on
        ? .success("\(target.title): Remote Control is back on.") : .failure(.noReply)
}

/// Reconnects sessions in order without waiting on each one. A session Claude resumes reconnects
/// by itself about a second after its wake message, so that's confirmed from Claude's log while
/// the next session is being typed. Any that don't come back, or failed only because Claude wasn't
/// ready, get one full try at the end. `report` is called once per session.
func wakeMany(_ ids: [String], report: (String, Result<WakeDone, WakeError>) -> Void) {
    var pending: [(id: String, since: Date)] = []
    var again: [String] = []
    func settle(final: Bool) {
        pending.removeAll { item in
            if claudeLogLines(since: item.since, about: item.id).contains(where: { $0.contains("Enabling remote control for session \(item.id)") }) {
                log("Claude reconnected \(item.id) by itself after the wake message")
                report(item.id, .success("\(session(item.id)?.title ?? "That session"): Remote Control is back on."))
                return true
            }
            if final || Date().timeIntervalSince(item.since) > 15 { again.append(item.id); return true }
            return false
        }
    }
    for id in ids {
        let result = wake(id, verifyLater: true)
        switch result {
        case .success(let done) where done.pendingSince != nil:
            pending.append((id, done.pendingSince!))
        case .failure(let error) where error.worthRetrying:
            log("Wake \(id): will try again after the others")
            again.append(id)
        default:
            report(id, result)
        }
        settle(final: false)
    }
    _ = poll(seconds: 15) { settle(final: false); return pending.isEmpty }
    settle(final: true)
    for id in again { report(id, wake(id)) }
}

/// Runs `check` every `every` seconds until it's true or `seconds` pass.
func poll(seconds: Double, every: Double = 0.2, _ check: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    repeat {
        if autoreleasepool(invoking: check) { return true }
        usleep(useconds_t(every * 1_000_000))
    } while Date() < deadline
    return autoreleasepool(invoking: check)
}

/// Claude's log lines about one session since `start` (from the last 300 KB, so it's quick).
func claudeLogLines(since start: Date, about id: String) -> [Substring] {
    guard let handle = try? FileHandle(forReadingFrom: claudeLog) else { return [] }
    defer { try? handle.close() }
    let size = handle.seekToEndOfFile()
    handle.seek(toFileOffset: size > 300_000 ? size - 300_000 : 0)
    let since = logStamp(start.addingTimeInterval(-1))
    return String(decoding: handle.readDataToEndOfFile(), as: UTF8.self).split(separator: "\n")
        .filter { $0.contains(id) && $0.prefix(19) >= since }
}

/// Whether Claude has started this session's process since it launched (only then can it take
/// /remote-control). Claude logs "Mapping internal session X" when it does.
func sessionStarted(_ id: String) -> Bool {
    RemoteControlStatus.startedSessions().contains(id)
}

enum CommandOutcome { case on, switchedOff, notRunning, nothing }

/// Types /remote-control into the open session and reads Claude's log for what it did.
func runRemoteControlCommand(_ id: String, pid: pid_t, since start: Date) -> CommandOutcome {
    type(remoteControlCommand, into: pid, pressReturn: false)
    usleep(300_000)
    // Escape closes Claude's command menu, so Return sends exactly what was typed. (With the menu
    // open, Return can rewrite the text and leave it in the box.)
    pressKey(53, pid)
    usleep(150_000)
    pressReturn(pid)
    var outcome = CommandOutcome.nothing
    _ = poll(seconds: 8) {
        let lines = claudeLogLines(since: start, about: id)
        if lines.contains(where: { $0.contains("Enabling remote control for session \(id)") }) { outcome = .on }
        else if lines.contains(where: { $0.contains("Disabling remote control for session \(id)") }) { outcome = .switchedOff }
        else if lines.contains(where: { $0.contains("Cannot toggle remote control for \(id)") }) { outcome = .notRunning }
        return outcome != .nothing
    }
    switch outcome {
    case .on: log("Turned Remote Control on for \(id) with /remote-control")
    case .notRunning: log("/remote-control: \(id) isn't running")
    default: break
    }
    return outcome
}

/// Whether Claude's log has a line containing `text` since `start`.
func claudeLogContains(_ text: String, since start: Date) -> Bool {
    guard let handle = try? FileHandle(forReadingFrom: claudeLog) else { return false }
    defer { try? handle.close() }
    let size = handle.seekToEndOfFile()
    handle.seek(toFileOffset: size > 400_000 ? size - 400_000 : 0)
    let since = logStamp(start.addingTimeInterval(-1))
    for line in String(decoding: handle.readDataToEndOfFile(), as: UTF8.self).split(separator: "\n") where line.contains(text) {
        if line.prefix(19) >= since { return true }
    }
    return false
}

/// A time as Claude's log writes it ("2026-11-01 08:22:05", local time). Those stamps sort as
/// text, so lines are compared without parsing a date for each one.
func logStamp(_ date: Date) -> String {
    logStampFormat.lock.lock(); defer { logStampFormat.lock.unlock() }
    return logStampFormat.formatter.string(from: date)
}

private let logStampFormat: (formatter: DateFormatter, lock: NSLock) = {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.dateFormat = "yyyy-MM-dd HH:mm:ss"
    return (f, NSLock())
}()
