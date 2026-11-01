// The menu bar item, the setup window (QR code to link a phone, and the typing permission), and
// the popup that opens the right settings when something Remote Keeper needs is off (Checks.swift).

import AppKit
import Combine
import ApplicationServices
import CoreImage.CIFilterBuiltins
import ServiceManagement
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let keeper = Keeper()
    let updater = Updater()
    private var statusItem: NSStatusItem!
    private var setupWindow: NSWindow?
    private var checklistWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        updateIcon()
        // The menu bar icon shows a warning while a setting Remote Keeper needs is off.
        Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in self?.updateIcon() }
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        keeper.onChange = { [weak self] in self?.refreshSetup() }
        keeper.onNeedsSettings = { [weak self] in self?.showChecklist() }
        keeper.start()
        updater.start()

        if keeper.store.current.setupDone != true {
            // First launch: open at login by default, then show setup.
            try? SMAppService.mainApp.register()
            keeper.store.update { $0.setupDone = true }
            showSetup()
        } else if !missingRequirements().isEmpty {
            showChecklist()
        }
    }

    private func updateIcon() {
        let missing = !missingRequirements().isEmpty
        let image = NSImage(systemSymbolName: missing ? "exclamationmark.arrow.circlepath" : "arrow.clockwise.circle",
                            accessibilityDescription: missing ? "Remote Keeper needs a setting turned on" : "Remote Keeper")
        image?.isTemplate = true
        statusItem.button?.image = image
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showSetup()
        return false
    }

    // MARK: Menu (rebuilt each time it opens, so it's always current)

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let title = NSMenuItem(title: "Remote Keeper", action: nil, keyEquivalent: "")
        title.isEnabled = false
        menu.addItem(title)

        let launch = claudeApp()?.launchDate
        let lines = [
            !relayConfigured ? "No relay set up in this build"
                : keeper.relayConnected ? (keeper.phoneLinked ? "Phone linked" : "No phone linked yet") : "Connecting to the relay…",
            launch.map { "Claude running since \(DateFormatter.localizedString(from: $0, dateStyle: .none, timeStyle: .short))" } ?? "Claude isn't running",
        ]
        for line in lines {
            let item = NSMenuItem(title: line, action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let missing = missingRequirements().count
        if missing > 0 {
            menu.addItem(item(missing == 1 ? "⚠︎ Turn On 1 Setting…" : "⚠︎ Turn On \(missing) Settings…", #selector(openChecklist)))
        }
        menu.addItem(item(keeper.phoneLinked ? "Link Another Phone…" : "Link Your Phone…", #selector(openSetup)))
        let watched = keeper.offlineWatched().count
        let wake = item(watched > 0 ? "Reconnect Offline Sessions (\(min(watched, maxBatch)))" : "Your Sessions Are Connected", #selector(wakeWatched))
        wake.isEnabled = watched > 0
        menu.addItem(wake)
        menu.addItem(.separator())
        if let release = updater.available {
            menu.addItem(item("Update to \(release.version)…", #selector(installUpdate)))
        } else {
            menu.addItem(item("Check for Updates…", #selector(checkUpdates)))
        }
        let login = item("Open at Login", #selector(toggleLogin))
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)
        menu.addItem(item("Unlink All Phones…", #selector(unlinkAll)))
        menu.addItem(.separator())
        menu.addItem(item("Quit Remote Keeper", #selector(quit), key: "q"))
    }

    private func item(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    @objc private func openSetup() { showSetup() }
    @objc private func wakeWatched() { keeper.wakeWatched() }
    @objc private func quit() { NSApp.terminate(nil) }

    @objc private func openChecklist() { showChecklist() }
    @objc private func checkUpdates() { updater.check(interactive: true) }
    @objc private func installUpdate() { updater.install() }

    @objc private func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() } else { try SMAppService.mainApp.register() }
        } catch {
            log("Open at Login: \(error.localizedDescription)")
        }
    }

    @objc private func unlinkAll() {
        let alert = NSAlert()
        alert.messageText = "Unlink all phones?"
        alert.informativeText = "Every phone that scanned the QR code stops working with this Mac, and the QR code changes. Scan the new one to link a phone again."
        alert.addButton(withTitle: "Unlink")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            keeper.unlinkAllPhones()
            showSetup()
        }
    }

    // MARK: Setup window

    func showSetup() {
        if setupWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 700), styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = "Remote Keeper"
            window.isReleasedWhenClosed = false
            window.center()
            setupWindow = window
        }
        refreshSetup()
        NSApp.activate(ignoringOtherApps: true)
        setupWindow?.makeKeyAndOrderFront(nil)
    }

    private func refreshSetup() {
        guard let window = setupWindow else { return }
        window.contentView = NSHostingView(rootView: SetupView(
            url: keeper.store.pairingURL,
            phoneLinked: keeper.phoneLinked,
            close: { [weak self, weak window] in
                window?.close()
                if !missingRequirements().isEmpty { self?.showChecklist() }
            }))
    }

    // MARK: Settings popup

    func showChecklist() {
        if checklistWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 360), styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = "Remote Keeper"
            window.isReleasedWhenClosed = false
            window.level = .floating   // stays above System Settings while you switch things on
            window.contentView = NSHostingView(rootView: ChecklistView(close: { [weak window] in window?.close() }))
            window.center()
            checklistWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        checklistWindow?.makeKeyAndOrderFront(nil)
        updateIcon()
    }
}

func qrImage(_ text: String) -> NSImage {
    let filter = CIFilter.qrCodeGenerator()
    filter.message = Data(text.utf8)
    filter.correctionLevel = "M"
    guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 10, y: 10)) else { return NSImage() }
    let rep = NSCIImageRep(ciImage: output)
    let image = NSImage(size: rep.size)
    image.addRepresentation(rep)
    return image
}

struct SetupView: View {
    let url: URL
    let phoneLinked: Bool
    let close: () -> Void
    @State private var typingAllowed = AXIsProcessTrusted()
    @State private var copied = false
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Set up Remote Keeper").font(.system(size: 22, weight: .bold))
                Text("Reconnect your Claude Code sessions' Remote Control from your phone.")
                    .foregroundStyle(.secondary)
            }

            step(1, done: phoneLinked, title: "Scan with your phone's camera") {
                if !relayConfigured {
                    Text("This build has no relay set up. Download Remote Keeper from github.com/\(releasesRepo)/releases, or run your own relay and set REMOTE_KEEPER_HOST and REMOTE_KEEPER_APP_KEY.")
                        .font(.callout).foregroundStyle(.secondary)
                } else {
                HStack(alignment: .top, spacing: 16) {
                    Image(nsImage: qrImage(url.absoluteString))
                        .interpolation(.none)
                        .resizable()
                        .frame(width: 168, height: 168)
                        .padding(8)
                        .background(Color.white)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                    VStack(alignment: .leading, spacing: 8) {
                        Text(phoneLinked ? "Your phone is linked." : "Waiting for your phone…")
                            .fontWeight(.medium)
                        Text("Then add the page to your Home Screen, so it opens like an app and can alert you when Claude restarts.")
                            .font(.callout).foregroundStyle(.secondary)
                        Text("Already using Keeper on your phone? In Keeper, tap ＋ and scan this code to add this Mac.")
                            .font(.callout).foregroundStyle(.secondary)
                        Button(copied ? "Copied" : "Copy Link") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(url.absoluteString, forType: .string)
                            copied = true
                        }
                        Text("Anyone with this code can reconnect your sessions, so keep it to yourself.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                }
            }

            step(2, done: typingAllowed, title: "Allow typing") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("To reconnect a session, Remote Keeper opens it in the Claude app and types one fixed message. macOS asks you to allow that once.")
                        .font(.callout).foregroundStyle(.secondary)
                    if !typingAllowed {
                        Button("Open Accessibility Settings…") { requirements.first { $0.id == "typing" }?.open() }
                    } else {
                        Text("Allowed.").fontWeight(.medium)
                    }
                }
            }

            Text("In the Claude app, keep Settings → Claude Code → “Connect new sessions to Remote Control” on.")
                .font(.caption).foregroundStyle(.secondary)

            HStack {
                Spacer()
                Button(phoneLinked && typingAllowed ? "Done" : "Finish Later", action: close)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 500)
        .onReceive(timer) { _ in typingAllowed = AXIsProcessTrusted() }
    }

    private func step<Content: View>(_ number: Int, done: Bool, title: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                Circle().fill(done ? Color.green : Color.accentColor.opacity(0.15)).frame(width: 28, height: 28)
                if done {
                    Image(systemName: "checkmark").font(.system(size: 13, weight: .bold)).foregroundStyle(.white)
                } else {
                    Text("\(number)").font(.system(size: 14, weight: .bold)).foregroundStyle(Color.accentColor)
                }
            }
            VStack(alignment: .leading, spacing: 10) {
                Text(title).font(.headline)
                content()
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .controlBackgroundColor)))
    }
}
