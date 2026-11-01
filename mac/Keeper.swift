// What the phone can ask for, and the restart alerts. The phone can only: get the status of your
// chosen sessions, list sessions to choose from, choose up to 10, and ask to wake chosen ones. Waking always sends the same fixed
// message, so nothing a phone sends is ever typed or run on this computer.

import AppKit
import ApplicationServices
import Foundation

let maxBatch = 10
let maxWatched = 10   // you choose up to 10 sessions; only those are watched and reconnected
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

    var relayConnected: Bool { relay?.connected == true }
    var phoneLinked: Bool { store.current.phoneSeenAt != nil }

    func start() {
        connect()
        watchForRestarts()
    }

    private func connect() {
        relay = RelayConnection(keys: ChannelKeys(secret: store.secretData),
                                onMessage: { [weak self] message in self?.queue.async { self?.handle(message) } },
                                onState: { [weak self] up in
                                    log(up ? "Connected to the relay" : "Disconnected from the relay")
                                    DispatchQueue.main.async { self?.onChange?() }
                                })
        relay.start()
    }

    /// A new secret: every linked phone stops working, and the QR code changes.
    func unlinkAllPhones() {
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
        case "settings":
            // From the phone's "Show on Mac" button: opens the settings popup here. Nothing else.
            DispatchQueue.main.async { self.onNeedsSettings?() }
        case "choices":
            // Sessions to choose from: most recent first (pinned ones are marked).
            let choices: [[String: Any]] = liveSessions().prefix(60).map { s in
                ["id": s.id, "title": String(s.title.prefix(120)), "pinned": s.pinned, "last": Int(s.lastTurn)]
            }
            relay.send(["t": "choices", "sessions": choices])
        case "set":
            let live = Set(liveSessions().map(\.id))
            let ids = ((message["ids"] as? [String]) ?? []).filter { live.contains($0) }
            var unique: [String] = []
            for id in ids where !unique.contains(id) { unique.append(id) }
            store.update { $0.watched = Array(unique.prefix(maxWatched)) }
            sendState()
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
        let launch = claudeApp()?.launchDate
        let live = Dictionary(liveSessions().map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let sessions: [[String: Any]] = store.watched.compactMap { live[$0] }.map { s in
            ["id": s.id, "title": String(s.title.prefix(120)), "pinned": s.pinned, "last": Int(s.lastTurn),
             "on": likelyConnected(s, since: launch), "waking": waking.contains(s.id)]
        }
        relay.send([
            "t": "state",
            "mac": ["name": Host.current().localizedName ?? "Mac", "version": keeperVersion],
            "claude": ["running": launch != nil, "since": launch.map { Int($0.timeIntervalSince1970 * 1000) as Any } ?? NSNull()],
            "locked": screenLocked(),
            "ax": AXIsProcessTrusted(),
            "claudeSetting": claudeConnectsNewSessions() == true,
            "max": maxWatched,
            "sessions": sessions,
        ])
    }

    // MARK: Waking

    /// Wakes sessions one at a time (each takes about 10–20 seconds). Call on `queue`.
    func enqueueWake(_ ids: [String]) {
        guard !ids.isEmpty else { sendState(); return }
        ids.forEach { waking.insert($0) }
        sendState()
        for id in ids {
            wakeQueue.async {
                let result = wake(id)
                self.queue.async {
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
        }
    }

    func offlineWatched() -> [String] {
        let launch = claudeApp()?.launchDate
        let live = Dictionary(uniqueKeysWithValues: liveSessions().map { ($0.id, $0) })
        return store.watched.filter { id in live[id].map { !likelyConnected($0, since: launch) } ?? false }
    }

    func wakeWatched() {
        queue.async { self.enqueueWake(Array(self.offlineWatched().filter { !self.waking.contains($0) }.prefix(maxBatch))) }
    }

    // MARK: Restart alerts

    /// Tells your phone when Claude restarts (that's when every session loses Remote Control).
    /// It only offers to reconnect; nothing is woken until you tap.
    private func watchForRestarts() {
        Thread.detachNewThread {
            var lastLaunch = claudeApp()?.launchDate
            while true {
                sleep(10)
                let launch = claudeApp()?.launchDate
                defer { if launch != nil { lastLaunch = launch } }
                guard let launch, launch != lastLaunch else { continue }
                log("Claude restarted")
                sleep(45)   // let it settle, and let sessions you open yourself reconnect
                let offline = self.offlineWatched()
                self.queue.async { self.sendState() }
                guard !offline.isEmpty else { continue }
                let computer = Host.current().localizedName ?? "your Mac"
                let count = offline.count == 1 ? "1 of your sessions" : "\(offline.count) of your sessions"
                self.relay.push(["t": "alert", "title": "Claude restarted on \(computer)", "offline": offline.count,
                                 "body": "Remote Control is off for \(count). Tap to reconnect."])
            }
        }
    }
}
