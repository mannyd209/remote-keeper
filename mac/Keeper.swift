// What the phone can ask for, and the alerts. The phone can only: get the status of your chosen
// sessions, list sessions to choose from, choose up to 10, ask to reconnect chosen ones, show the
// settings popup, install the latest signed update, mark new sessions as seen, and turn new-session
// alerts on or off. Waking always sends the same fixed
// message, so nothing a phone sends is ever typed or run on this computer.

import AppKit
import ApplicationServices
import Foundation

let maxBatch = 50   // reconnected one after another
let maxWatched = 500  // effectively no limit (the web app lets you choose 10 per computer; the iPhone app, any number)
let supportDir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Remote Keeper")
let configURL = ProcessInfo.processInfo.environment["REMOTE_KEEPER_CONFIG"].map { URL(fileURLWithPath: $0) }
    ?? supportDir.appendingPathComponent("config.json")

func log(_ message: String) {
    let stamp = ISO8601DateFormatter().string(from: Date())
    FileHandle.standardError.write(Data("\(stamp) \(message)\n".utf8))
}

// MARK: - Config

struct Config: Codable {
    var secret: String?          // base64url, 32 bytes; shown only inside the QR code
    var watched: [String]?
    var phoneSeenAt: Double?     // last message from a linked phone
    var setupDone: Bool?
    var notifiedUpdate: String?  // the newest release we already sent a notification about
    var loginOff: Bool?          // you turned off Open at Login (see Lifeline.swift)
    var known: [String]?         // sessions your phone has already been told about (new ones show up on it)
    var alertNew: Bool?          // also send a notification for a new session (a phone's setting; off by default)
}

final class Store {
    private let lock = NSLock()
    private var config: Config

    init() {
        config = (try? Data(contentsOf: configURL)).flatMap { try? JSONDecoder().decode(Config.self, from: $0) } ?? Config()
        if config.secret.flatMap({ Data(base64URL: $0) })?.count != 32 { config.secret = Store.newSecret() }
        save()
    }

    static func newSecret() -> String { Data((0..<32).map { _ in UInt8.random(in: 0...255) }).base64URL }

    var current: Config { lock.lock(); defer { lock.unlock() }; return config }

    func update(_ change: (inout Config) -> Void) {
        lock.lock()
        change(&config)
        save()
        lock.unlock()
    }

    private func save() {
        try? FileManager.default.createDirectory(at: configURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(config) else { return }
        try? data.write(to: configURL, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: configURL.path)
    }

    var secretData: Data { Data(base64URL: current.secret ?? "") ?? Data() }
    var watched: [String] { current.watched ?? [] }
    var pairingURL: URL { URL(string: "https://\(relayIsLocal ? "localhost:8787" : relayHost)/#k=\(current.secret ?? "")")! }
}

// MARK: - The helper

final class Keeper {
    let store = Store()
    private(set) var relay: RelayConnection!
    private let queue = DispatchQueue(label: "keeper")
    private let wakeQueue = DispatchQueue(label: "wake")
    private var waking = Set<String>()   // only touched on `queue`
    var onChange: (() -> Void)?          // called on the main queue when the menu should refresh
    var onNeedsSettings: (() -> Void)?   // called on the main queue to show the settings popup
    var onUpdateRequested: (() -> Void)? // called on the main queue: the phone asked to update this Mac
    private(set) var availableUpdate: String?  // a newer release on GitHub, if any (only touched on `queue`)

    var relayConnected: Bool { relay?.connected == true }
    var phoneLinked: Bool { store.current.phoneSeenAt != nil }

    func start() {
        // The first run counts every existing session as known, so only sessions made from now on
        // show up as new.
        let existing = allSessions().map(\.id)
        store.update { config in
            let exists = Set(existing)
            config.known = config.known.map { $0.filter(exists.contains) } ?? existing   // forget deleted sessions
        }
        connect()
        watchForRestarts()
        // The relay's "will": your phone hears if this Mac goes quiet without sleeping or quitting.
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            self?.awake = false
            self?.relay.withdrawWill()
        }
        center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.awake = true
            self?.sendWill()
        }
        // Refreshed every 30 minutes: phones only trust an alert for a day.
        Timer.scheduledTimer(withTimeInterval: 30 * 60, repeats: true) { [weak self] _ in self?.sendWill() }
    }

    private var awake = true   // only touched on the main queue

    /// The alert the relay sends if this Mac goes quiet (see Relay.setWill).
    func sendWill() {
        guard awake, relayConnected, !store.watched.isEmpty else { return }
        let computer = Host.current().localizedName ?? "your Mac"
        log("Offline alert armed with the relay")
        relay.setWill(["t": "alert", "kind": "offline", "title": "Remote Keeper is offline on \(computer)",
                       "body": "It hasn't checked in for 5 minutes, so your sessions there aren't being watched. Check that the Mac is on, awake and online."])
    }

    /// Before quitting: a Mac you closed on purpose doesn't need an alert.
    func withdrawWill() { relay?.withdrawWill() }

    private func connect() {
        relay = RelayConnection(keys: ChannelKeys(secret: store.secretData),
                                onMessage: { [weak self] message in self?.queue.async { self?.handle(message) } },
                                onState: { [weak self] up in
                                    log(up ? "Connected to the relay" : "Disconnected from the relay")
                                    DispatchQueue.main.async {
                                        if up { self?.sendWill() }
                                        self?.onChange?()
                                    }
                                })
        relay.start()
    }

    /// A new secret: every linked phone stops working, and the QR code changes.
    func unlinkAllPhones() {
        relay.withdrawWill()   // the old phones shouldn't hear this Mac went offline
        relay.stop()
        store.update { $0.secret = Store.newSecret(); $0.phoneSeenAt = nil }
        connect()
        onChange?()
    }

    // MARK: Messages from a phone

    private func handle(_ message: [String: Any]) {
        let firstTime = store.current.phoneSeenAt == nil
        store.update { $0.phoneSeenAt = Date().timeIntervalSince1970 }
        if firstTime {
            log("A phone linked")
            DispatchQueue.main.async { self.onChange?() }
        }
        switch message["t"] as? String {
        case "hello":
            sendState()
        case "update":
            // From the phone's Update button: installs the latest GitHub release, and only if it's
            // signed by MannyD Labs and notarized (see Updater.swift).
            DispatchQueue.main.async { self.onUpdateRequested?() }
        case "settings":
            // From the phone's "Show on Mac" button: opens the settings popup here. Nothing else.
            DispatchQueue.main.async { self.onNeedsSettings?() }
        case "choices":
            // Sessions to choose from: most recent first (pinned ones are marked).
            let choices: [[String: Any]] = liveSessions().prefix(300).map { s in
                ["id": s.id, "title": String(s.title.prefix(120)), "pinned": s.pinned, "last": Int(s.lastTurn)]
            }
            relay.send(["t": "choices", "sessions": choices])
        case "set":
            let live = Set(liveSessions().map(\.id))
            let ids = ((message["ids"] as? [String]) ?? []).filter { live.contains($0) }
            var unique: [String] = []
            for id in ids where !unique.contains(id) { unique.append(id) }
            store.update { $0.watched = Array(unique.prefix(maxWatched)); $0.known = Array(Set(($0.known ?? []) + unique)) }
            sendState()
            if unique.isEmpty { relay.withdrawWill() } else { DispatchQueue.main.async { self.sendWill() } }
        case "seen":
            // "Not now" on the phone's new-sessions card: stop offering these.
            let ids = ((message["ids"] as? [String]) ?? []).prefix(maxWatched)
            store.update { $0.known = Array(Set(($0.known ?? []) + ids)) }
            sendState()
        case "prefs":
            if let on = message["alertNew"] as? Bool {
                store.update { $0.alertNew = on }
                sendState()
            }
        case "wake":
            let live = Set(liveSessions().map(\.id)), chosen = Set(store.watched)
            let ids = ((message["ids"] as? [String]) ?? []).filter { live.contains($0) && chosen.contains($0) && !waking.contains($0) }
            enqueueWake(Array(ids.prefix(maxBatch)))
        default:
            break
        }
    }

    // MARK: State for the phone

    /// Your chosen sessions (up to 10), in the order you picked them, with their status.
    func sendState() {
        let status = RemoteControlStatus.now()
        let launch = status.launch
        let live = Dictionary(liveSessions().map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let sessions: [[String: Any]] = store.watched.compactMap { live[$0] }.map { s in
            ["id": s.id, "title": String(s.title.prefix(120)), "pinned": s.pinned, "last": Int(s.lastTurn),
             "on": status.isOn(s), "waking": waking.contains(s.id)]
        }
        relay.send([
            "t": "state",
            "mac": ["name": Host.current().localizedName ?? "Mac", "version": keeperVersion],
            "claude": ["running": launch != nil, "since": launch.map { Int($0.timeIntervalSince1970 * 1000) as Any } ?? NSNull()],
            "locked": screenLocked(),
            "ax": AXIsProcessTrusted(),
            "claudeSetting": claudeConnectsNewSessions() == true,
            "max": maxWatched,
            "update": availableUpdate ?? NSNull(),
            "sessions": sessions,
            "new": newSessions().map { s in ["id": s.id, "title": String(s.title.prefix(120)), "pinned": s.pinned, "last": Int(s.lastTurn)] },
            "alertNew": store.current.alertNew == true,
        ])
    }

    /// Sessions made since your phone last looked: not chosen, not archived, folder still there, and
    /// past their first turn (so Claude has named them). Newest first, at most 10.
    func newSessions(from live: [Session]? = nil) -> [Session] {
        let known = Set(store.current.known ?? []), watched = Set(store.watched)
        return Array((live ?? liveSessions()).filter { $0.turns > 0 && !known.contains($0.id) && !watched.contains($0.id) }.prefix(10))
    }

    /// What the phone shows that can change without any session dropping: your chosen sessions'
    /// names and pins, and the new sessions. When it changes, the phone hears right away.
    func shownSignature(_ sessions: [Session]) -> String {
        let live = Dictionary(sessions.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let chosen = store.watched.compactMap { live[$0] }.map { "\($0.id)\u{1}\($0.title)\u{1}\($0.pinned)" }
        return (chosen + ["|"] + newSessions(from: sessions).map { "\($0.id)\u{1}\($0.title)" }).joined(separator: "\u{2}")
    }

    // MARK: Updates

    /// A newer Remote Keeper is out (or nil): show it on the phone, and send one notification per
    /// version so you can update from there.
    func setAvailableUpdate(_ version: String?) {
        queue.async {
            guard self.availableUpdate != version else { return }
            self.availableUpdate = version
            self.sendState()
            guard let version, self.store.current.notifiedUpdate != version, self.phoneLinked else { return }
            self.store.update { $0.notifiedUpdate = version }
            let computer = Host.current().localizedName ?? "your Mac"
            self.relay.push(["t": "alert", "kind": "update", "title": "Remote Keeper \(version) is available",
                             "body": "For \(computer). Tap to update it from your phone.", "offline": self.offlineWatched().count])
        }
    }

    // MARK: Waking

    /// Wakes sessions one at a time (each takes about 10–20 seconds). Call on `queue`.
    func enqueueWake(_ ids: [String]) {
        guard !ids.isEmpty else { sendState(); return }
        ids.forEach { waking.insert($0) }
        sendState()
        for id in ids { wakeQueue.async { self.runWake(id, isRetry: false) } }
    }

    /// One reconnect, on the wake queue. If Claude simply wasn't ready (no message box yet, or it
    /// didn't switch to the session), it goes to the back of the line once before the phone hears
    /// it failed: right after a restart the first few can come too early.
    private func runWake(_ id: String, isRetry: Bool) {
        let result = wake(id)
        if !isRetry, case .failure(let error) = result, error.worthRetrying {
            log("Wake \(id): will try again after the others")
            wakeQueue.async { self.runWake(id, isRetry: true) }
            sleep(2)
            return
        }
        queue.async {
            self.waking.remove(id)
            let name = session(id)?.title ?? "That session"
            switch result {
            case .success(let text): self.relay.send(["t": "result", "id": id, "ok": true, "text": text])
            case .failure(let error):
                self.relay.send(["t": "result", "id": id, "ok": false, "text": "\(name): \(error.description)"])
                if case .noAccessibility = error { DispatchQueue.main.async { self.onNeedsSettings?() } }
            }
            self.sendState()
        }
        sleep(2)
    }

    func offlineWatched() -> [String] {
        let status = RemoteControlStatus.now()
        let live = Dictionary(liveSessions().map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        return store.watched.filter { id in live[id].map { !status.isOn($0) } ?? false }
    }

    func wakeWatched() {
        queue.async { self.enqueueWake(Array(self.offlineWatched().filter { !self.waking.contains($0) }.prefix(maxBatch))) }
    }

    // MARK: Alerts

    /// Watches your chosen sessions and tells your phone when Remote Control goes off for any of
    /// them: Claude restarted or quit, or a session's switch was turned off. It only offers to
    /// reconnect; nothing is reconnected until you tap.
    private func watchForRestarts() {
        Thread.detachNewThread {
            var lastLaunch = claudeApp()?.launchDate
            var lastOffline = autoreleasepool { Set(self.offlineWatched()) }
            // Read inside a pool too: this thread has none of its own (see pass()).
            var (lastShown, lastNew) = autoreleasepool { () -> (String, Set<String>) in
                let live = liveSessions()
                return (self.shownSignature(live), Set(self.newSessions(from: live).map(\.id)))
            }
            var quitSince: Date?
            var quitAlerted = false
            // Each pass runs in its own autorelease pool: a detached thread has none, so without it
            // every object Foundation autoreleased here (log text, dates, session files) piled up
            // forever, about 280 MB a minute, until macOS killed Remote Keeper for low memory.
            func pass() {
                Lifeline.heartbeat()
                let computer = Host.current().localizedName ?? "your Mac"
                let launch = claudeApp()?.launchDate

                // Claude quit: say so once if it stays closed for a minute.
                guard let launch else {
                    quitSince = quitSince ?? Date()
                    if !quitAlerted, Date().timeIntervalSince(quitSince!) > 60, !self.store.watched.isEmpty {
                        quitAlerted = true
                        self.queue.async { self.sendState() }
                        let n = self.store.watched.count
                        self.relay.push(["t": "alert", "title": "Claude quit on \(computer)", "offline": n,
                                         "body": "Remote Control is off for \(n == 1 ? "your session" : "all \(n) of your sessions"). Tap to reconnect; Remote Keeper opens Claude."])
                    }
                    lastOffline = Set(self.store.watched)
                    return
                }
                quitSince = nil
                quitAlerted = false

                // A chosen session was renamed or pinned, or a new session appeared: tell the phone.
                let live = liveSessions()
                let shown = self.shownSignature(live)
                if shown != lastShown {
                    lastShown = shown
                    self.queue.async { self.sendState() }
                    let fresh = self.newSessions(from: live)
                    let added = fresh.filter { !lastNew.contains($0.id) }
                    lastNew = Set(fresh.map(\.id))
                    if !added.isEmpty, self.store.current.alertNew == true, self.phoneLinked {
                        let title = added.count == 1 ? "\u{201C}\(added[0].title)\u{201D}" : "\(added.count) new sessions"
                        self.relay.push(["t": "alert", "kind": "new", "title": "New session on \(computer)",
                                         "body": "\(title). Tap to keep \(added.count == 1 ? "it" : "them") connected."])
                    }
                }

                // Claude restarted: every session dropped. Give it a moment, then report.
                if launch != lastLaunch {
                    lastLaunch = launch
                    log("Claude restarted")
                    sleep(45)   // let it settle, and let sessions you open yourself reconnect
                    let offline = self.offlineWatched()
                    lastOffline = Set(offline)
                    self.queue.async { self.sendState() }
                    guard !offline.isEmpty else { return }
                    let count = offline.count == 1 ? "1 of your sessions" : "\(offline.count) of your sessions"
                    self.relay.push(["t": "alert", "title": "Claude restarted on \(computer)", "offline": offline.count,
                                     "body": "Remote Control is off for \(count). Tap to reconnect."])
                    return
                }

                // A session went off (its switch, or it dropped) or came back.
                let offline = Set(self.offlineWatched())
                guard offline != lastOffline else { return }
                let newlyOff = offline.subtracting(lastOffline).filter { id in self.queue.sync { !self.waking.contains(id) } }
                lastOffline = offline
                self.queue.async { self.sendState() }
                guard !newlyOff.isEmpty else { return }
                let title = newlyOff.count == 1 ? (session(newlyOff.first!)?.title ?? "A session") : "\(newlyOff.count) sessions"
                self.relay.push(["t": "alert", "title": "Remote Control off on \(computer)", "offline": offline.count,
                                 "body": "\(title) can't be reached from your phone. Tap to reconnect."])
            }
            while true {
                sleep(10)
                autoreleasepool { pass() }
            }
        }
    }
}
