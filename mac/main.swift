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

let keeperVersion = "0.3.0"

let args = Array(CommandLine.arguments.dropFirst()).filter { !$0.hasPrefix("-NS") && !$0.hasPrefix("-Apple") }
switch args.first ?? "" {
case "list":
    let launch = claudeApp()?.launchDate
    print("Claude started: \(launch.map { "\($0)" } ?? "not running")")
    for s in liveSessions().prefix(40) {
        print("\(likelyConnected(s, since: launch) ? "on " : "off") \(s.pinned ? "★" : " ") \(s.title)\t\(s.id)")
    }
case "wake":
    let target = args.dropFirst().first { !$0.hasPrefix("--") } ?? ""
    let live = liveSessions()
    guard let match = live.first(where: { $0.id == target }) ?? live.first(where: { $0.title.lowercased() == target.lowercased() })
            ?? live.first(where: { $0.title.lowercased().contains(target.lowercased()) && !target.isEmpty }) else {
        print("No session matches '\(target)'. Run: remote-keeper list"); exit(1)
    }
    switch wake(match.id, dryRun: args.contains("--dry-run")) {
    case .success(let message): print(args.contains("--dry-run") ? message : "✅ \(message)")
    case .failure(let error): print("⚠️ \(error.description)"); exit(1)
    }
case "version":
    print(keeperVersion)
default:
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
