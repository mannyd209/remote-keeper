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
    let turns: Int
    let userEnabled: Bool? // Claude's per-session Remote Control switch (nil: never set)
}

func allSessions() -> [Session] {
    let fm = FileManager.default
    var found: [Session] = []
    for account in (try? fm.contentsOfDirectory(atPath: sessionsRoot.path)) ?? [] {
        let accountDir = sessionsRoot.appendingPathComponent(account)
        for org in (try? fm.contentsOfDirectory(atPath: accountDir.path)) ?? [] {
            let orgDir = accountDir.appendingPathComponent(org)
            for file in (try? fm.contentsOfDirectory(atPath: orgDir.path)) ?? [] where file.hasPrefix("local_") && file.hasSuffix(".json") {
                guard let data = try? Data(contentsOf: orgDir.appendingPathComponent(file)),
                      let d = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                      let id = d["sessionId"] as? String else { continue }
                let lastTurn = (d["lastTurnEdgeAt"] as? Double) ?? (d["lastActivityAt"] as? Double) ?? 0
                found.append(Session(
                    id: id,
                    title: (d["title"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "Untitled",
                    cwd: d["cwd"] as? String ?? "",
                    pinned: d["isStarred"] as? Bool == true,
                    archived: d["isArchived"] as? Bool == true,
                    lastTurn: lastTurn,
                    turns: d["completedTurns"] as? Int ?? 0,
                    userEnabled: d["remoteControlUserEnabled"] as? Bool))
            }
        }
    }
    return found
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
        guard let handle = try? FileHandle(forReadingFrom: claudeLog) else { return [:] }
        defer { try? handle.close() }
        let size = handle.seekToEndOfFile()
        handle.seek(toFileOffset: size > 3_000_000 ? size - 3_000_000 : 0)
        let text = String(decoding: handle.readDataToEndOfFile(), as: UTF8.self)
        let format = DateFormatter()
        format.dateFormat = "yyyy-MM-dd HH:mm:ss"
        var events: [String: Bool] = [:]
        var recent: String?   // the session the next "Remote control enabled" belongs to
        for line in text.split(separator: "\n") {
            guard let date = format.date(from: String(line.prefix(19))), date >= start.addingTimeInterval(-1) else { continue }
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

enum WakeError: Error, CustomStringConvertible {
    case noAccessibility, locked, noSession, claudeNotRunning, noMessageBox, noReply

    var description: String {
        switch self {
        case .noAccessibility: return "Remote Keeper needs permission to type. Open Remote Keeper on your computer and turn on Allow Typing."
        case .locked: return "your Mac is locked, so nothing was typed. Unlock it and try again."
        case .noSession: return "that session is gone (archived, or its folder moved)."
        case .claudeNotRunning: return "the Claude app didn't open."
        case .noMessageBox: return "Claude's message box didn't get focus, so nothing was typed."
        case .noReply: return "Remote Control didn't come back on. Check the session in the Claude app."
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

    // Give someone using the Mac a moment to pause, so the switch to Claude isn't a surprise.
    let deadline = Date().addingTimeInterval(30)
    while secondsSinceInput() < 8 && Date() < deadline { sleep(2) }

    if claudeApp() == nil {
        if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: claudeBundleID) {
            NSWorkspace.shared.openApplication(at: appURL, configuration: NSWorkspace.OpenConfiguration())
        }
        for _ in 0..<30 where claudeApp() == nil { sleep(1) }
        guard claudeApp() != nil else { return .failure(.claudeNotRunning) }
        sleep(12)   // let it load its sessions
    }
    guard let app = claudeApp() else { return .failure(.claudeNotRunning) }

    NSWorkspace.shared.open(URL(string: "claude://claude.ai/epitaxy/\(id)")!)
    sleep(3)
    app.activate()
    var focused = false
    for _ in 0..<5 {
        if messageBoxFocused(app.processIdentifier) { focused = true; break }
        sleep(1)
    }
    guard focused else { return .failure(.noMessageBox) }
    // Check again right before typing: /remote-control switches it off if it's already on.
    if RemoteControlStatus.now().isOn(session(id) ?? target) { return .success("\(target.title): Remote Control is already on.") }

    // 1. Claude's own /remote-control command: no Claude usage, and it also works when the
    //    session's switch was turned off.
    let started = Date()
    type(remoteControlCommand, into: app.processIdentifier, pressReturn: false)
    usleep(700_000)
    pressReturn(app.processIdentifier)
    for attempt in 0..<16 {
        sleep(1)
        if attempt == 3, RemoteControlStatus.logEvents(since: started)[id] == nil {
            pressReturn(app.processIdentifier)   // the first Return only picked it from the command menu
        }
        if let on = RemoteControlStatus.logEvents(since: started)[id] {
            if on {
                log("Turned Remote Control on for \(id) with /remote-control")
                return .success("\(target.title): Remote Control is back on.")
            }
            // It was on after all and the command switched it off: switch it back on.
            log("/remote-control switched \(id) off; switching it back on")
            type(remoteControlCommand, into: app.processIdentifier, pressReturn: false)
            usleep(700_000)
            pressReturn(app.processIdentifier)
            sleep(4)
            return RemoteControlStatus.logEvents(since: started)[id] == true
                ? .success("\(target.title): Remote Control is on.")
                : .failure(.noReply)
        }
    }

    // 2. Fallback: a session reconnects by itself once it runs a turn (unless its switch is off).
    guard session(id)?.userEnabled != false else { return .failure(.noReply) }
    let before = session(id) ?? target
    type(wakeText, into: app.processIdentifier)
    log("Sent the wake message to \(id)")
    for _ in 0..<40 {
        sleep(3)
        if let now = session(id), now.turns > before.turns || now.lastTurn > before.lastTurn {
            for _ in 0..<8 {
                if RemoteControlStatus.logEvents(since: started)[id] == true { return .success("\(target.title): Remote Control is back on.") }
                sleep(2)
            }
            return .success("\(target.title) got the message, so its Remote Control should reconnect in a few seconds.")
        }
    }
    return .failure(.noReply)
}
