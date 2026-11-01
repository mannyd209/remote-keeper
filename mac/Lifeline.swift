// Keeps Remote Keeper running.
//
// It runs as a login agent (Contents/Library/LaunchAgents/com.mannydlabs.remotekeeper.agent.plist,
// registered with SMAppService) that launchd keeps alive: if macOS kills it (low memory), it crashes
// or it exits with an error, launchd starts it again within seconds. "Quit Remote Keeper" exits
// cleanly, so it stays quit until you open it again or log in.
//
// A copy opened by hand (Finder, an update) hands over to launchd's copy. If you turned off Open at
// Login, or macOS is waiting for you to allow it in Login Items, it runs as a plain app instead.
//
// It also watches its own memory, restarting itself if it ever grows past `memoryLimitMB`, and logs
// how the previous run ended, so a problem like the 2026-11-01 leak shows up in Remote Keeper.log.

import AppKit
import Foundation
import ServiceManagement

let agentLabel = "com.mannydlabs.remotekeeper.agent"
let agentService = SMAppService.agent(plistName: "\(agentLabel).plist")
let launchedByAgent = ProcessInfo.processInfo.environment["REMOTE_KEEPER_AGENT"] == "1"
let memoryLimitMB = 400

enum Lifeline {
    private static let stateURL = supportDir.appendingPathComponent("lifeline.json")

    private struct State: Codable {
        var pid: Int32
        var version: String
        var started: Double
        var heartbeat: Double
        var memoryMB: Int
        var clean: Bool
    }

    private static let lock = NSLock()
    private static var state: State?

    /// Runs first, before the app starts. Returns false if this copy should exit because
    /// launchd's copy is (or is about to be) running.
    static func takeOver(loginOff: Bool) -> Bool {
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
            .filter { $0.processIdentifier != getpid() }
        if launchedByAgent {
            others.forEach { $0.terminate() }   // a copy opened by hand hands over to this one
            return true
        }
        if loginOff { return others.isEmpty }   // run as a plain app, once
        if agentService.status != .enabled {
            if SMAppService.mainApp.status == .enabled { try? SMAppService.mainApp.unregister() }   // 0.3.5 and earlier
            do { try agentService.register() } catch { log("Login agent: \(error.localizedDescription)") }
        }
        guard agentService.status == .enabled else {
            log("Login agent not allowed yet (\(agentService.status.rawValue)); running as a plain app")
            return others.isEmpty
        }
        kickstart()
        if agentRunning() { log("Handed over to the login agent"); return false }
        // Registered but not loaded (launchd lost it): register it again.
        log("Login agent didn't start; registering it again")
        try? agentService.unregister()
        try? agentService.register()
        kickstart()
        if agentRunning() { log("Handed over to the login agent"); return false }
        log("Login agent still isn't running; running as a plain app")
        return true
    }

    /// Waits up to 5 seconds for launchd's copy to be running.
    private static func agentRunning() -> Bool {
        for _ in 0..<25 {
            if NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
                .contains(where: { $0.processIdentifier != getpid() }) { return true }
            usleep(200_000)
        }
        return false
    }

    /// Starts launchd's copy if it isn't running (no-op if it is).
    static func kickstart() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = ["kickstart", "gui/\(getuid())/\(agentLabel)"]
        try? process.run()
        process.waitUntilExit()
    }

    /// Open at Login on or off. Off: a plain copy takes over, then the agent is removed (which ends
    /// this copy if launchd started it). On: the agent starts and this copy hands over to it.
    static func setOpenAtLogin(_ on: Bool, store: Store) {
        store.update { $0.loginOff = !on }
        if on {
            do { try agentService.register() } catch { log("Login agent: \(error.localizedDescription)") }
            kickstart()
        } else {
            reopenSoon()
            try? agentService.unregister()
        }
    }

    // MARK: How the last run ended

    static func noteStart() {
        lock.lock(); defer { lock.unlock() }
        if let data = try? Data(contentsOf: stateURL), let last = try? JSONDecoder().decode(State.self, from: data), !last.clean {
            let when = Date(timeIntervalSince1970: last.heartbeat)
            log("The last run (\(last.version), pid \(last.pid)) stopped unexpectedly: last seen \(ISO8601DateFormatter().string(from: when)), using \(last.memoryMB) MB")
        }
        let now = Date().timeIntervalSince1970
        state = State(pid: getpid(), version: keeperVersion, started: now, heartbeat: now, memoryMB: footprintMB(), clean: false)
        save()
        log("Running as \(launchedByAgent ? "the login agent (restarts if it stops)" : "a plain app")")
    }

    /// Called every pass of the watcher (10 seconds): records that we're alive and checks memory.
    static func heartbeat() {
        let mb = footprintMB()
        lock.lock()
        state?.heartbeat = Date().timeIntervalSince1970
        state?.memoryMB = mb
        save()
        lock.unlock()
        if mb > memoryLimitMB {
            log("Memory use is \(mb) MB (limit \(memoryLimitMB) MB); restarting")
            restart()
        }
    }

    static func noteCleanExit() {
        lock.lock(); defer { lock.unlock() }
        state?.clean = true
        save()
    }

    /// Exits so a fresh copy starts: launchd restarts its copy after a non-zero exit; a plain
    /// copy opens itself again first.
    static func restart() {
        if !launchedByAgent { reopenSoon() }
        exit(70)
    }

    private static func reopenSoon() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "sleep 2; open \"\(Bundle.main.bundleURL.path)\""]
        try? process.run()
    }

    private static func save() {
        guard let state, let data = try? JSONEncoder().encode(state) else { return }
        try? FileManager.default.createDirectory(at: supportDir, withIntermediateDirectories: true)
        try? data.write(to: stateURL, options: .atomic)
    }

    /// This process's memory as Activity Monitor counts it (including compressed and swapped).
    static func footprintMB() -> Int {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return result == KERN_SUCCESS ? Int(info.phys_footprint / 1_048_576) : 0
    }
}
