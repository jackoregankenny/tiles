import AppKit
import CryptoKit

/// Updates from GitHub Releases, no framework. The latest release of the repo named by the app's
/// RFUpdateRepo Info.plist key carries "<App>.zip" and "<App>.zip.sha256". An update is installed
/// only if the zip matches its checksum and holds this app's bundle id at the release's version.
/// Development builds (version "dev") never update, so `./build.sh` output is never replaced.
final class Updater {
    enum State: Equatable { case idle, checking, upToDate, available(String), installing, installed(String), failed(String) }

    let app: String
    let repo: String
    let current: String
    private(set) var state: State = .idle { didSet { onChange?() } }
    var onChange: (() -> Void)?
    /// Asked before restarting into a new version, e.g. "is the launcher closed?".
    var canRelaunch: () -> Bool = { true }
    private var timer: Timer?

    init(app: String) {
        self.app = app
        repo = Bundle.main.object(forInfoDictionaryKey: "RFUpdateRepo") as? String ?? ""
        current = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }

    var enabled: Bool { !repo.isEmpty && current != "dev" }

    /// "v1.10.0" vs "1.9.2": numeric, part by part.
    static func isNewer(_ a: String, than b: String) -> Bool {
        func parts(_ s: String) -> [Int] { s.trimmingCharacters(in: CharacterSet(charactersIn: "vV")).split(separator: ".").map { Int($0) ?? 0 } }
        let x = parts(a), y = parts(b)
        for i in 0..<max(x.count, y.count) {
            let p = i < x.count ? x[i] : 0, q = i < y.count ? y[i] : 0
            if p != q { return p > q }
        }
        return false
    }

    /// Checks shortly after launch, then every six hours, installing what it finds.
    func startAutomatic() {
        stopAutomatic()
        guard enabled else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in
            guard let self, self.timer != nil else { return }
            self.check(install: true)
        }
        timer = Timer.scheduledTimer(withTimeInterval: 6 * 3600, repeats: true) { [weak self] _ in self?.check(install: true) }
        timer?.tolerance = 600
    }

    func stopAutomatic() {
        timer?.invalidate()
        timer = nil
    }

    func check(install: Bool, relaunch: Bool = true, done: (() -> Void)? = nil) {
        guard enabled, state != .checking, state != .installing else { done?(); return }
        if case .installed = state { done?(); return }
        state = .checking
        var req = URLRequest(url: URL(string: "https://api.github.com/repos/\(repo)/releases/latest")!)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("\(app)/\(current)", forHTTPHeaderField: "User-Agent")
        URLSession.shared.dataTask(with: req) { data, _, error in
            let obj = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            let tag = (obj?["tag_name"] as? String ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
            let assets = (obj?["assets"] as? [[String: Any]] ?? []).reduce(into: [String: URL]()) { m, a in
                if let n = a["name"] as? String, let u = (a["browser_download_url"] as? String).flatMap(URL.init) { m[n] = u }
            }
            DispatchQueue.main.async {
                guard !tag.isEmpty else {
                    self.state = .failed(error?.localizedDescription ?? "No release found")
                    done?(); return
                }
                guard Updater.isNewer(tag, than: self.current) else { self.state = .upToDate; done?(); return }
                self.state = .available(tag)
                guard install, let zip = assets["\(self.app).zip"], let sum = assets["\(self.app).zip.sha256"] else { done?(); return }
                self.install(tag, zip: zip, sum: sum, relaunch: relaunch, done: done)
            }
        }.resume()
    }

    private func install(_ version: String, zip: URL, sum: URL, relaunch: Bool, done: (() -> Void)?) {
        state = .installing
        let finish = { (result: State) in DispatchQueue.main.async { self.state = result; done?() } }
        DispatchQueue.global(qos: .utility).async {
            do {
                let expected = String(decoding: try Data(contentsOf: sum), as: UTF8.self)
                    .split(whereSeparator: { $0 == " " || $0.isNewline }).first.map(String.init)?.lowercased() ?? ""
                let data = try Data(contentsOf: zip)
                let actual = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
                guard expected.count == 64, actual == expected else { return finish(.failed("Checksum mismatch")) }

                let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("\(self.app)-update-\(version)")
                try? FileManager.default.removeItem(at: tmp)
                try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
                let archive = tmp.appendingPathComponent("\(self.app).zip")
                try data.write(to: archive)
                let ditto = Process()
                ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
                ditto.arguments = ["-x", "-k", archive.path, tmp.path]
                try ditto.run()
                ditto.waitUntilExit()

                let fresh = tmp.appendingPathComponent("\(self.app).app")
                guard let b = Bundle(url: fresh), b.bundleIdentifier == Bundle.main.bundleIdentifier,
                      (b.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) == version
                else { return finish(.failed("The download is not \(self.app) \(version)")) }

                _ = try FileManager.default.replaceItemAt(Bundle.main.bundleURL, withItemAt: fresh)
                try? FileManager.default.removeItem(at: tmp)
                finish(.installed(version))
                if relaunch { DispatchQueue.main.async { self.relaunchWhenIdle() } }
            } catch {
                finish(.failed(error.localizedDescription))
            }
        }
    }

    /// Restarts into the new version, waiting until the app is not in use.
    private func relaunchWhenIdle() {
        guard canRelaunch() else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 60) { [weak self] in self?.relaunchWhenIdle() }
            return
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "sleep 1; /usr/bin/open \"$0\"", Bundle.main.bundlePath]
        try? p.run()
        NSApp.terminate(nil)
    }

    /// The menu item for this state.
    var menuTitle: String {
        guard enabled else { return current == "dev" ? "Development Build (no updates)" : "Updates Not Configured" }
        switch state {
        case .idle: return "Check for Updates…"
        case .checking: return "Checking for Updates…"
        case .upToDate: return "\(app) \(current) Is Up to Date"
        case .available(let v): return "Update to \(v)…"
        case .installing: return "Installing Update…"
        case .installed(let v): return "\(v) Installed: Restarts When Idle"
        case .failed: return "Update Check Failed: Try Again"
        }
    }
}
