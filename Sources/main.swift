import AppKit
import Carbon.HIToolbox

/// ~/.config/tiles/config.json (or $TILES_HOME). Everything is optional.
struct TilesConfig {
    // ⌃⌥⌘ + letters and numbers, leaving ⌃⌥ + keys free for Rectangle-style snapping tools
    // (Hop, Rectangle) and ⌃⌥⌘ + ←/→ for moving between displays.
    static let defaultHotkeys: [String: String] = [
        "ctrl+opt+cmd+t": "tile",
        "ctrl+opt+cmd+shift+t": "auto toggle",
        "ctrl+opt+cmd+r": "restore",
        "ctrl+opt+cmd+h": "focus left", "ctrl+opt+cmd+j": "focus down", "ctrl+opt+cmd+k": "focus up", "ctrl+opt+cmd+l": "focus right",
        "ctrl+opt+cmd+shift+h": "swap left", "ctrl+opt+cmd+shift+j": "swap down",
        "ctrl+opt+cmd+shift+k": "swap up", "ctrl+opt+cmd+shift+l": "swap right",
        "ctrl+opt+cmd+m": "promote",
        "ctrl+opt+cmd+equal": "grow", "ctrl+opt+cmd+minus": "shrink",
        "ctrl+opt+cmd+f": "float",
        "ctrl+opt+cmd+1": "layout master", "ctrl+opt+cmd+2": "layout columns", "ctrl+opt+cmd+3": "layout rows",
        "ctrl+opt+cmd+4": "layout grid", "ctrl+opt+cmd+5": "layout monocle",
    ]

    var hotkeys = defaultHotkeys
    var raw: [String: Any] = [:]

    static var dir: String {
        ProcessInfo.processInfo.environment["TILES_HOME"] ?? (NSHomeDirectory() as NSString).appendingPathComponent(".config/tiles")
    }
    static var path: String { (dir as NSString).appendingPathComponent("config.json") }

    static func load() -> TilesConfig {
        var c = TilesConfig()
        guard let data = FileManager.default.contents(atPath: path),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return c }
        c.raw = obj
        c.hotkeys = HotKeys.merged(defaultHotkeys, obj["hotkeys"] as? [String: String])
        return c
    }

    func apply(to t: Tiler) {
        if let l = raw["layout"] as? String, let mode = Tiling(key: l) { t.layout = mode }
        if let g = raw["gap"] as? Double { t.gap = CGFloat(g) }
        if let r = raw["ratio"] as? Double { t.ratio = CGFloat(r) }
        if let f = raw["float"] as? [String] { t.floating.formUnion(f.map { $0.lowercased() }) }
        if let a = raw["auto"] as? Bool, a != t.auto { t.setAuto(a) }
    }

    static func edit() {
        if !FileManager.default.fileExists(atPath: path) {
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            let sample: [String: Any] = ["layout": "master", "gap": 10, "ratio": 0.55, "auto": false,
                                         "float": ["FaceTime"],
                                         "hotkeys": ["ctrl+opt+cmd+t": "tile", "ctrl+opt+cmd+r": "none"]]
            if let data = try? JSONSerialization.data(withJSONObject: sample, options: [.prettyPrinted, .sortedKeys]) {
                FileManager.default.createFile(atPath: path, contents: data)
            }
        }
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }
}

let args = CommandLine.arguments

if args.contains("--selftest") { TilesTest.run() }

if args.contains("--update-now") {
    let u = Updater(app: "Tiles")
    print("current:", u.current, "· repo:", u.repo.isEmpty ? "none" : u.repo)
    var finished = false
    u.check(install: true, relaunch: false) { finished = true }
    while !finished && RunLoop.main.run(mode: .default, before: .distantFuture) {}
    print("result:", u.state, "·", u.menuTitle)
    exit(0)
}

// --probe reports what Tiles would tile on this Space without moving anything.
if args.contains("--probe") {
    let t = Tiler()
    TilesConfig.load().raw["float"].flatMap { $0 as? [String] }.map { t.floating.formUnion($0.map { $0.lowercased() }) }
    let wins = WindowCore.windows()
    print("accessibility trusted:", AXIsProcessTrusted())
    print("windows on this Space:", wins.count, "· tileable:", wins.filter(t.tileable).count)
    for w in wins { print("  ", t.tileable(w) ? "tile " : "float", w.appName, Geo.flip(w.frame).integral) }
    exit(0)
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let tiler = Tiler()
    let hotkeys = HotKeys()
    let updater = Updater(app: "Tiles")
    var status: NSStatusItem!
    var labels: [String: String] = [:]   // action -> "⌃⌥T"

    func applicationDidFinishLaunching(_ n: Notification) {
        status = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let menu = NSMenu()
        menu.delegate = self
        status.menu = menu
        tiler.onChange = { [weak self] in self?.updateIcon() }
        NSAppleEventManager.shared().setEventHandler(self, andSelector: #selector(handleURL(_:reply:)),
                                                     forEventClass: AEEventClass(kInternetEventClass), andEventID: AEEventID(kAEGetURL))
        AX.ensureTrusted()
        reload()
        // Off with "autoUpdate": false in config.json.
        if TilesConfig.load().raw["autoUpdate"] as? Bool != false { updater.startAutomatic() }
    }

    func reload() {
        let c = TilesConfig.load()
        c.apply(to: tiler)
        hotkeys.removeAll()
        labels = [:]
        for (combo, action) in c.hotkeys.sorted(by: { $0.key < $1.key }) {
            if hotkeys.register(combo, { [weak self] in self?.tiler.perform(action) }) {
                labels[action.lowercased()] = HotKeys.symbols(combo)
            } else {
                NSLog("Tiles: could not register %@ (in use or unknown key)", combo)
            }
        }
        updateIcon()
    }

    func updateIcon() {
        status.button?.image = NSImage(systemSymbolName: tiler.auto ? "square.grid.2x2.fill" : "square.grid.2x2",
                                       accessibilityDescription: "Tiles")
    }

    /// tiles://tile, tiles://layout/grid, tiles://auto/toggle, tiles://focus/left …
    @objc func handleURL(_ event: NSAppleEventDescriptor, reply: NSAppleEventDescriptor) {
        guard let s = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue, let u = URL(string: s) else { return }
        tiler.perform(([u.host ?? ""] + u.pathComponents.filter { $0 != "/" }).joined(separator: " "))
    }

    // MARK: menu, rebuilt each time it opens so it shows the current state

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        if !AXIsProcessTrusted() {
            add(menu, "Grant Accessibility Access…", "") {
                AX.ensureTrusted()
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
            }
            menu.addItem(.separator())
        }
        add(menu, "Tile Now", "tile") { [tiler] in tiler.tile() }
        add(menu, "Auto-Tile", "auto toggle", on: tiler.auto) { [tiler] in tiler.setAuto(!tiler.auto) }
        add(menu, "Restore Original Positions", "restore") { [tiler] in tiler.restore() }
        menu.addItem(.separator())
        for l in Tiling.allCases {
            add(menu, l.rawValue, "layout \(l.key)", on: tiler.layout == l) { [tiler] in tiler.setLayout(l) }
        }
        menu.addItem(.separator())
        let front = NSWorkspace.shared.frontmostApplication?.localizedName ?? "This App"
        add(menu, "Float \(front)", "float", on: tiler.floating.contains(front.lowercased())) { [tiler] in tiler.toggleFloat() }
        add(menu, "Gaps: \(Int(tiler.gap)) pt · Master: \(Int(tiler.ratio * 100))%", "") {}.isEnabled = false
        menu.addItem(.separator())
        add(menu, updater.menuTitle, "") { [updater] in updater.check(install: true) }.isEnabled = updater.enabled
        add(menu, "Edit Config…", "") { TilesConfig.edit() }
        add(menu, "Reload Config", "") { [weak self] in self?.reload() }
        add(menu, "Quit Tiles", "") { NSApp.terminate(nil) }
    }

    private var actions: [() -> Void] = []

    @discardableResult
    private func add(_ menu: NSMenu, _ title: String, _ action: String, on: Bool = false, _ run: @escaping () -> Void) -> NSMenuItem {
        let label = labels[action].map { "\t\($0)" } ?? ""
        let item = NSMenuItem(title: title + label, action: #selector(menuAction(_:)), keyEquivalent: "")
        item.target = self
        item.tag = actions.count
        item.state = on ? .on : .off
        actions.append(run)
        menu.addItem(item)
        return item
    }

    @objc private func menuAction(_ item: NSMenuItem) {
        guard item.tag < actions.count else { return }
        let run = actions[item.tag]
        // Let the menu close and focus return to the window underneath first.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: run)
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
