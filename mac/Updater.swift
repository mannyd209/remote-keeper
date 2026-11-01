// Updates from GitHub Releases. Remote Keeper checks the latest release twice a day, and when you
// choose Update it downloads the DMG and installs it only if the app inside is signed by MannyD
// Labs (team 28SERP79H5), has our bundle id, and is notarized by Apple.

import AppKit
import Foundation

let releasesRepo = "mannyd209/remote-keeper"
let teamIdentifier = "28SERP79H5"
let releaseAsset = "Remote-Keeper.dmg"

struct Release {
    let version: String
    let notes: String
    let download: URL
}

final class Updater {
    private(set) var available: Release?
    var onChange: (() -> Void)?

    func start() {
        check()
        Timer.scheduledTimer(withTimeInterval: 12 * 3600, repeats: true) { [weak self] _ in self?.check() }
    }

    /// Asks GitHub for the latest release. `interactive`: say so when you're already up to date.
    func check(interactive: Bool = false) {
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(releasesRepo)/releases/latest")!, timeoutInterval: 20)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("RemoteKeeper/\(keeperVersion)", forHTTPHeaderField: "User-Agent")
        URLSession.shared.dataTask(with: request) { data, _, _ in
            var found: Release?
            if let data, let release = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
               let tag = release["tag_name"] as? String,
               let assets = release["assets"] as? [[String: Any]],
               let asset = assets.first(where: { $0["name"] as? String == releaseAsset }),
               let link = (asset["browser_download_url"] as? String).flatMap(URL.init(string:)) {
                let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
                if isNewer(version, than: keeperVersion) {
                    found = Release(version: version, notes: release["body"] as? String ?? "", download: link)
                }
            }
            DispatchQueue.main.async {
                self.available = found
                self.onChange?()
                if interactive { self.explain() }
            }
        }.resume()
    }

    private func explain() {
        let alert = NSAlert()
        if let release = available {
            alert.messageText = "Remote Keeper \(release.version) is available"
            alert.informativeText = "You have \(keeperVersion).\n\n" + String(release.notes.prefix(600))
            alert.addButton(withTitle: "Update")
            alert.addButton(withTitle: "Later")
            NSApp.activate(ignoringOtherApps: true)
            if alert.runModal() == .alertFirstButtonReturn { install() }
        } else {
            alert.messageText = "Remote Keeper is up to date"
            alert.informativeText = "You have the latest version, \(keeperVersion)."
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
        }
    }

    /// Checks GitHub, then installs the newest release if it's newer (from the phone's Update).
    func installLatest() {
        let previous = onChange
        onChange = { [weak self] in
            self?.onChange = previous
            previous?()
            if self?.available != nil { self?.install() }
        }
        check()
    }

    /// Downloads, checks and installs the update, then relaunches.
    func install() {
        guard let release = available else { return }
        URLSession.shared.downloadTask(with: release.download) { file, _, error in
            guard let file else {
                DispatchQueue.main.async { self.failed("The download didn't finish (\(error?.localizedDescription ?? "unknown error")).") }
                return
            }
            let result = Self.installDMG(file)
            DispatchQueue.main.async {
                switch result {
                case .success(let script): Self.relaunch(with: script)
                case .failure(let message): self.failed(message.text)
                }
            }
        }.resume()
    }

    struct Message: Error { let text: String }

    private static func installDMG(_ dmg: URL) -> Result<String, Message> {
        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent("RemoteKeeperUpdate-\(UUID().uuidString)")
        try? fm.createDirectory(at: work, withIntermediateDirectories: true)
        let mount = work.appendingPathComponent("mount")
        guard run("/usr/bin/hdiutil", ["attach", dmg.path, "-nobrowse", "-readonly", "-mountpoint", mount.path]).status == 0 else {
            return .failure(Message(text: "The update couldn't be opened."))
        }
        defer { _ = run("/usr/bin/hdiutil", ["detach", mount.path, "-force"]) }
        let newApp = mount.appendingPathComponent("Remote Keeper.app")
        let staged = work.appendingPathComponent("Remote Keeper.app")
        guard (try? fm.copyItem(at: newApp, to: staged)) != nil else { return .failure(Message(text: "The update didn't contain Remote Keeper.")) }

        // Only ever install our own, notarized app.
        let info = run("/usr/bin/codesign", ["-dv", "--verbose=2", staged.path]).output
        guard run("/usr/bin/codesign", ["--verify", "--deep", "--strict", staged.path]).status == 0,
              info.contains("TeamIdentifier=\(teamIdentifier)"),
              info.contains("Identifier=com.mannydlabs.remotekeeper"),
              run("/usr/sbin/spctl", ["--assess", "--type", "execute", staged.path]).status == 0 else {
            return .failure(Message(text: "The update isn't signed by MannyD Labs, so it wasn't installed."))
        }

        // Swap the app once this one has quit, then open the new one.
        let current = Bundle.main.bundleURL.path
        let script = """
        while kill -0 \(getpid()) 2>/dev/null; do sleep 0.2; done
        rm -rf "\(current)" && mv "\(staged.path)" "\(current)" && open "\(current)"
        rm -rf "\(work.path)"
        """
        return .success(script)
    }

    private static func relaunch(with script: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script]
        try? process.run()
        NSApp.terminate(nil)
    }

    private func failed(_ text: String) {
        let alert = NSAlert()
        alert.messageText = "Couldn't update Remote Keeper"
        alert.informativeText = text + "\n\nYou can download it from github.com/\(releasesRepo)/releases."
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    @discardableResult
    private static func run(_ tool: String, _ args: [String]) -> (status: Int32, output: String) {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = args
        process.standardOutput = pipe
        process.standardError = pipe
        guard (try? process.run()) != nil else { return (-1, "") }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}

func isNewer(_ version: String, than other: String) -> Bool {
    let a = version.split(separator: ".").map { Int($0) ?? 0 }, b = other.split(separator: ".").map { Int($0) ?? 0 }
    for i in 0..<max(a.count, b.count) {
        let x = i < a.count ? a[i] : 0, y = i < b.count ? b[i] : 0
        if x != y { return x > y }
    }
    return false
}
