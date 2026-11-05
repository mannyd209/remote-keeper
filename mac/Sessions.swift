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
            userEnabled: d["remoteControlUserEnabled"] as? Bool)
    }
}

/// Sessions you can wake: not archived, and their folder still exists.
func liveSessions() -> [Session] {
    allSessions()
        .filter { !$0.archived && FileManager.default.fileExists(atPath: $0.cwd) }
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
        return RemoteControlStatus(launch: launch, events: logEvents(since: launch))
    }

    func isOn(_ s: Session) -> Bool {
        guard let launch else { return false }
        if s.userEnabled == false { return false }
        if let on = events[s.id] { return on }
        return s.lastTurn / 1000 > launch.timeIntervalSince1970
    }

    /// The last thing Claude's log says about each session's Remote Control since `start`.
    static func logEvents(since start: Date) -> [String: Bool] {
        autoreleasepool { readLogEvents(since: start) }
    }

    private static func readLogEvents(since start: Date) -> [String: Bool] {
        guard let handle = try? FileHandle(forReadingFrom: claudeLog) else { return [:] }
        defer { try? handle.close() }
        let size = handle.seekToEndOfFile()
        handle.seek(toFileOffset: size > 3_000_000 ? size - 3_000_000 : 0)
        let text = String(decoding: handle.readDataToEndOfFile(), as: UTF8.self)
        let since = logStamp(start.addingTimeInterval(-1))
        var events: [String: Bool] = [:]
        var recent: String?   // the session the next "Remote control enabled" belongs to
        for line in text.split(separator: "\n") where line.contains("emote control") || line.contains("Mapping internal session ") {
            guard line.prefix(19) >= since else { continue }
            if let id = sessionId(after: "Enabling remote control for session ", in: line) {
                recent = id
            } else if let id = sessionId(after: "Disabling remote control for session ", in: line) {
                events[id] = false
                if recent == id { recent = nil }
            } else if let id = sessionId(after: "Mapping internal session ", in: line) {
                recent = id
            } else if line.contains("Remote control enabled"), let id = recent {
                events[id] = true
                recent = nil
            }
        }
        return events
    }

    private static func sessionId(after marker: String, in line: Substring) -> String? {
        guard let range = line.range(of: marker) else { return nil }
        return line[range.upperBound...].split(separator: " ").first.map(String.init)
    }
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

/// Checked right before anything is typed: Claude shows this session, its message box is empty,
/// and nobody is using the Mac. Typing goes to whatever box has focus, so without these a wake
/// could land in another session, or be mixed into what someone is typing.
func readyToType(_ id: String, pid: pid_t) -> WakeError? {
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

/// Finds the session's message box in Claude's front window and gives it focus.
func focusMessageBox(_ pid: pid_t) -> Bool {
    if messageBoxFocused(pid) { return true }
    let app = AXUIElementCreateApplication(pid)
    AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
    var window: CFTypeRef?
    guard AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &window) == .success
            || AXUIElementCopyAttributeValue(app, kAXMainWindowAttribute as CFString, &window) == .success,
          let root = window else {
        log("Focus: Claude has no front window")
        return false
    }
    // The message box is an editable text area; there's normally one, at the bottom.
    var boxes: [(AXUIElement, CGFloat)] = []
    func walk(_ element: AXUIElement, depth: Int) {
        guard depth < 40, boxes.count < 20 else { return }
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
    walk(root as! AXUIElement, depth: 0)
    guard let box = boxes.max(by: { $0.1 < $1.1 })?.0 else {
        log("Focus: no message box found in Claude's window")
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

/// Presses Return in the Claude process.
func pressReturn(_ pid: pid_t) {
    let source = CGEventSource(stateID: .hidSystemState)
    for down in [true, false] {
        CGEvent(keyboardEventSource: source, virtualKey: 36, keyDown: down)?.postToPid(pid)
    }
}

func wake(_ id: String, dryRun: Bool = false) -> Result<String, WakeError> {
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
    if let launched = app.launchDate, Date().timeIntervalSince(launched) < 45 {
        sleep(UInt32(45 - Date().timeIntervalSince(launched)))
    }

    // Open the session and make sure Claude actually switched to it.
    let link = URL(string: "claude://claude.ai/epitaxy/\(id)")!
    var switched = false
    for attempt in 0..<2 where !switched {
        bringClaudeForward(opening: link)
        for _ in 0..<8 where !switched {
            sleep(1)
            switched = shownSessionId() == id
        }
        if !switched { log("Wake \(id): Claude didn't switch to it (attempt \(attempt + 1))") }
    }
    guard switched else { return .failure(.wrongSession) }
    var focused = false
    for attempt in 0..<6 {
        if attempt == 3 { bringClaudeForward() }
        if focusMessageBox(app.processIdentifier) { focused = true; break }
        sleep(1)
    }
    let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "none"
    guard focused else {
        log("Wake \(id): no message box focus (front app: \(front), Claude active: \(app.isActive))")
        return .failure(.noMessageBox)
    }
    // Check again right before typing: a turn may have started meanwhile, and /remote-control
    // switches Remote Control off if it's already on.
    if turnInProgress(id) {
        guard waitForTurnToFinish(id) else { return .failure(.busy) }
        guard focusMessageBox(app.processIdentifier) else { return .failure(.noMessageBox) }
    }
    if RemoteControlStatus.now().isOn(session(id) ?? target) { return .success("\(target.title): Remote Control is already on.") }

    // 1. Claude's own /remote-control command: no Claude usage, and it also works when the
    //    session's switch was turned off. It only works while the session's process is running.
    let pid = app.processIdentifier
    if let problem = readyToType(id, pid: pid) { return .failure(problem) }
    let started = Date()
    switch runRemoteControlCommand(id, pid: pid, since: started) {
    case .on:
        return .success("\(target.title): Remote Control is back on.")
    case .switchedOff:
        // It was on after all and the command switched it off: switch it back on.
        log("/remote-control switched \(id) off; switching it back on")
        if let problem = readyToType(id, pid: pid) { return .failure(problem) }
        return runRemoteControlCommand(id, pid: pid, since: Date()) == .on
            ? .success("\(target.title): Remote Control is on.") : .failure(.noReply)
    case .notRunning, .nothing:
        break
    }

    // 2. The session isn't running (Claude only keeps a few running). One short message starts
    //    it; a session whose switch is on reconnects by itself after that turn, and otherwise
    //    /remote-control works now.
    let before = session(id) ?? target
    guard focusMessageBox(pid) else { return .failure(.noMessageBox) }
    if let problem = readyToType(id, pid: pid) { return .failure(problem) }
    let sent = Date()
    type(wakeText, into: pid)
    log("Sent the wake message to \(id) to start it")
    var startedTurn = false
    for _ in 0..<30 {
        sleep(2)
        if RemoteControlStatus.logEvents(since: sent)[id] == true { return .success("\(target.title): Remote Control is back on.") }
        if claudeLogContains("Mapping internal session \(id)", since: sent) { startedTurn = true; break }
        if let now = session(id), now.turns > before.turns || now.lastTurn > before.lastTurn { startedTurn = true; break }
    }
    guard startedTurn else { return .failure(.noReply) }
    sleep(4)
    if RemoteControlStatus.logEvents(since: sent)[id] == true || RemoteControlStatus.now().isOn(session(id) ?? target) {
        return .success("\(target.title): Remote Control is back on.")
    }
    guard focusMessageBox(pid) else { return .failure(.noMessageBox) }
    if let problem = readyToType(id, pid: pid) { return .failure(problem) }
    switch runRemoteControlCommand(id, pid: pid, since: Date()) {
    case .on: return .success("\(target.title): Remote Control is back on.")
    default: return .failure(.noReply)
    }
}

enum CommandOutcome { case on, switchedOff, notRunning, nothing }

/// Types /remote-control into the open session and reads Claude's log for what it did.
func runRemoteControlCommand(_ id: String, pid: pid_t, since start: Date) -> CommandOutcome {
    type(remoteControlCommand, into: pid, pressReturn: false)
    usleep(700_000)
    pressReturn(pid)
    for attempt in 0..<12 {
        sleep(1)
        if let on = RemoteControlStatus.logEvents(since: start)[id] {
            if on { log("Turned Remote Control on for \(id) with /remote-control") }
            return on ? .on : .switchedOff
        }
        if claudeLogContains("Cannot toggle remote control for \(id)", since: start) {
            log("/remote-control: \(id) isn't running")
            return .notRunning
        }
        // The first Return may only have picked it from the command menu. Press again only if
        // it's still this session and nobody is typing.
        if attempt == 3, shownSessionId() == id, secondsSinceInput() >= 3 { pressReturn(pid) }
    }
    return .nothing
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
