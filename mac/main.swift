// Remote Keeper for Claude Code (macOS).
//
// When the Claude desktop app restarts or updates, every Claude Code session drops Remote
// Control. Remote Keeper lets you reconnect them from your phone: it lives in the menu bar,
// links to the Remote Keeper web app on your phone with a QR code, and wakes the sessions you
// pick (see Sessions.swift). Messages go through an end-to-end encrypted relay (Relay.swift).
//
// Config: ~/Library/Application Support/Remote Keeper/config.json (mode 600)
//
// The app normally runs from the menu bar. For testing, the binary also takes:
//   list | wake <title or id> [--dry-run] | version

import AppKit
import Foundation

let keeperVersion = "0.3.12"

let args = Array(CommandLine.arguments.dropFirst()).filter { !$0.hasPrefix("-NS") && !$0.hasPrefix("-Apple") }
switch args.first ?? "" {
case "list":
    let status = RemoteControlStatus.now()
    print("Claude started: \(status.launch.map { "\($0)" } ?? "not running")")
    for s in liveSessions().prefix(40) {
        print("\(status.isOn(s) ? "on " : "off") \(s.pinned ? "★" : " ") \(s.title)\t\(s.id)")
    }
case "wake" where args.dropFirst().filter({ !$0.hasPrefix("--") }).count > 1:
    // Several session ids: the same quick pass the phone's Reconnect All uses.
    let started = Date()
    wakeMany(Array(args.dropFirst().filter { !$0.hasPrefix("--") })) { id, result in
        let t = String(format: "%5.1fs", Date().timeIntervalSince(started))
        switch result {
        case .success(let done): print("\(t) ✅ \(done.text)")
        case .failure(let error): print("\(t) ⚠️ \(session(id)?.title ?? id): \(error.description)")
        }
    }
    print(String(format: "Done in %.1fs", Date().timeIntervalSince(started)))
case "wake":
    let target = args.dropFirst().first { !$0.hasPrefix("--") } ?? ""
    let live = liveSessions()
    guard let match = live.first(where: { $0.id == target }) ?? live.first(where: { $0.title.lowercased() == target.lowercased() })
            ?? live.first(where: { $0.title.lowercased().contains(target.lowercased()) && !target.isEmpty }) else {
        print("No session matches '\(target)'. Run: remote-keeper list"); exit(1)
    }
    switch wake(match.id, dryRun: args.contains("--dry-run")) {
    case .success(let done): print(args.contains("--dry-run") ? done.text : "✅ \(done.text)")
    case .failure(let error): print("⚠️ \(error.description)"); exit(1)
    }
case "version":
    print(keeperVersion)
default:
    // Log to ~/Library/Logs/Remote Keeper.log (an app opened from Finder has nowhere else to log).
    let logFile = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Remote Keeper.log")
    if isatty(STDERR_FILENO) == 0, freopen(logFile.path, "a", stderr) != nil { setvbuf(stderr, nil, _IOLBF, 0) }
    log("Remote Keeper \(keeperVersion) started")
    let saved = (try? Data(contentsOf: configURL)).flatMap { try? JSONDecoder().decode(Config.self, from: $0) }
    guard Lifeline.takeOver(loginOff: saved?.loginOff == true) else { exit(0) }
    Lifeline.noteStart()
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
