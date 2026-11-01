// The settings Remote Keeper needs, how to tell whether each one is on, and the button that opens
// the exact place to turn it on. Shown in a popup whenever something is missing.

import AppKit
import Combine
import ApplicationServices
import ServiceManagement
import SwiftUI

struct Requirement: Identifiable {
    let id: String
    let title: String
    let detail: String
    let button: String
    let isMet: () -> Bool
    let open: () -> Void
}

/// Claude's own "Connect new sessions to Remote Control" switch (Settings → Claude Code), read from
/// its config file. nil when it has never been set.
func claudeConnectsNewSessions() -> Bool? {
    let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Claude/claude_desktop_config.json")
    guard let data = try? Data(contentsOf: url),
          let config = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
          let preferences = config["preferences"] as? [String: Any] else { return nil }
    return preferences["ccRemoteControlDefaultEnabled"] as? Bool
}

let requirements: [Requirement] = [
    Requirement(
        id: "typing",
        title: "Allow typing",
        detail: "In Accessibility, turn on Remote Keeper. It types one fixed message into Claude to reconnect a session.",
        button: "Open Accessibility Settings",
        isMet: { AXIsProcessTrusted() },
        open: {
            // Adds Remote Keeper to the list (so it is there to switch on), then opens the page.
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
        }),
    Requirement(
        id: "claude",
        title: "Connect new sessions to Remote Control",
        detail: "In Claude's Settings → Claude Code, turn on “Connect new sessions to Remote Control”. That's what lets a session reconnect by itself.",
        button: "Open Claude Settings",
        isMet: { claudeConnectsNewSessions() == true },
        open: {
            NSWorkspace.shared.open(URL(string: "claude://claude.ai/settings/claude-code")!)
            claudeApp()?.activate()
        }),
    Requirement(
        id: "login",
        title: "Open at login",
        detail: "In Login Items, allow Remote Keeper, so it's running after your Mac restarts.",
        button: "Open Login Items",
        // Only a problem when macOS is waiting for approval; if you turned it off yourself, that's your choice.
        isMet: { SMAppService.mainApp.status != .requiresApproval },
        open: { SMAppService.openSystemSettingsLoginItems() }),
]

func missingRequirements() -> [Requirement] { requirements.filter { !$0.isMet() } }

struct ChecklistView: View {
    let close: () -> Void
    @State private var met: [String: Bool] = Dictionary(uniqueKeysWithValues: requirements.map { ($0.id, $0.isMet()) })
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    private var allMet: Bool { met.values.allSatisfy { $0 } }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 48, height: 48)
                VStack(alignment: .leading, spacing: 2) {
                    Text(allMet ? "Remote Keeper is ready" : "Finish setting up Remote Keeper").font(.system(size: 17, weight: .bold))
                    Text(allMet ? "Everything it needs is turned on." : "Turn these on, and Remote Keeper can reconnect your sessions.")
                        .foregroundStyle(.secondary)
                }
            }
            VStack(spacing: 0) {
                ForEach(requirements) { item in
                    let ok = met[item.id] ?? false
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                            .font(.system(size: 20))
                            .foregroundStyle(ok ? Color.green : Color.orange)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(item.title).fontWeight(.semibold)
                            if !ok { Text(item.detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
                        }
                        Spacer(minLength: 8)
                        if ok {
                            Text("On").foregroundStyle(.secondary)
                        } else {
                            Button(item.button) { item.open() }
                        }
                    }
                    .padding(.vertical, 12)
                    if item.id != requirements.last?.id { Divider() }
                }
            }
            .padding(.horizontal, 14)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
            HStack {
                Spacer()
                Button(allMet ? "Done" : "Later", action: close).keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 520)
        .onReceive(timer) { _ in
            met = Dictionary(uniqueKeysWithValues: requirements.map { ($0.id, $0.isMet()) })
        }
    }
}
