import AppKit

enum Tiling: String, CaseIterable {
    case master = "Master & Stack", columns = "Columns", rows = "Rows", grid = "Grid", monocle = "Monocle"

    var key: String {
        switch self {
        case .master: return "master"
        case .columns: return "columns"
        case .rows: return "rows"
        case .grid: return "grid"
        case .monocle: return "monocle"
        }
    }

    init?(key: String) {
        switch key.lowercased() {
        case "master", "master-stack", "tall", "stack": self = .master
        case "columns", "cols": self = .columns
        case "rows": self = .rows
        case "grid": self = .grid
        case "monocle", "full": self = .monocle
        default: return nil
        }
    }

    /// Tiles for n windows in Cocoa coordinates. `a` is the screen area already inset by gap/2.
    func rects(count n: Int, area a: CGRect, ratio: CGFloat, gap: CGFloat) -> [CGRect] {
        guard n > 0 else { return [] }
        let part = Rects.part
        var out: [CGRect]
        switch self {
        case .monocle:
            out = Array(repeating: a, count: n)
        case .columns:
            out = (0..<n).map { part(a, CGFloat($0) / CGFloat(n), 1 / CGFloat(n), 0, 1) }
        case .rows:
            out = (0..<n).map { part(a, 0, 1, CGFloat($0) / CGFloat(n), 1 / CGFloat(n)) }
        case .master:
            if n == 1 { out = [a]; break }
            let r = min(max(ratio, 0.15), 0.85), k = CGFloat(n - 1)
            out = [part(a, 0, r, 0, 1)] + (0..<(n - 1)).map { part(a, r, 1 - r, CGFloat($0) / k, 1 / k) }
        case .grid:
            let cols = Int(ceil(Double(n).squareRoot())), rows = Int(ceil(Double(n) / Double(cols)))
            out = (0..<n).map { i in
                let row = i / cols
                let inRow = row == rows - 1 ? n - row * cols : cols   // last row stretches to fill
                return part(a, CGFloat(i - row * cols) / CGFloat(inRow), 1 / CGFloat(inRow),
                            CGFloat(row) / CGFloat(rows), 1 / CGFloat(rows))
            }
        }
        return out.map { Rects.withGaps($0, gap) }
    }
}

/// Best neighbour of `from` in a direction, preferring windows that overlap on the other axis.
func nearest(of from: CGRect, in dir: String, among others: [CGRect]) -> Int? {
    var best: (Int, CGFloat)?
    for (i, o) in others.enumerated() {
        let dx = o.midX - from.midX, dy = o.midY - from.midY   // Cocoa: +y is up
        let (along, across): (CGFloat, CGFloat)
        switch dir {
        case "left": (along, across) = (-dx, dy)
        case "right": (along, across) = (dx, dy)
        case "up": (along, across) = (dy, dx)
        case "down": (along, across) = (-dy, dx)
        default: return nil
        }
        guard along > 1 else { continue }
        let score = along + abs(across) * 2
        if best == nil || score < best!.1 { best = (i, score) }
    }
    return best?.0
}

final class Tiler {
    typealias Win = WindowCore.Win

    var layout: Tiling = .master
    var ratio: CGFloat = 0.55
    var gap: CGFloat = 10
    var floating: Set<String> = ["system settings", "calculator", "archive utility", "installer", "1password",
                                 "hop", "screenshot", "digital color meter", "font book", "raycast", "alfred"]
    var onChange: (() -> Void)?
    private(set) var auto = false
    private var order: [CGWindowID] = []           // tiling order, master first
    private var original: [CGWindowID: CGRect] = [:]
    private var poll: Timer?
    private var lastSignature: [CGWindowID] = []
    private var spaceObserver: NSObjectProtocol?

    func tileable(_ w: Win) -> Bool {
        guard !floating.contains(w.appName.lowercased()),
              AX.string(w.el, kAXSubroleAttribute) == kAXStandardWindowSubrole,
              !AX.bool(w.el, kAXMinimizedAttribute), !AX.bool(w.el, "AXFullScreen") else { return false }
        var settable: DarwinBoolean = false
        AXUIElementIsAttributeSettable(w.el, kAXSizeAttribute as CFString, &settable)
        return settable.boolValue
    }

    // MARK: tiling

    func tile() {
        guard AX.ensureTrusted() else { return }
        let wins = WindowCore.windows().filter(tileable)
        let ids = Set(wins.map(\.id))
        order.removeAll { !ids.contains($0) }
        for w in wins where !order.contains(w.id) { order.append(w.id) }   // new windows join the stack
        var byScreen: [NSScreen: [Win]] = [:]
        for w in wins { if let s = Geo.screen(containing: w.frame) { byScreen[s, default: []].append(w) } }
        for (screen, list) in byScreen {
            let sorted = list.sorted { (order.firstIndex(of: $0.id) ?? 0) < (order.firstIndex(of: $1.id) ?? 0) }
            let area = screen.visibleFrame.insetBy(dx: gap / 2, dy: gap / 2)
            for (w, r) in zip(sorted, layout.rects(count: sorted.count, area: area, ratio: ratio, gap: gap)) {
                if original[w.id] == nil { original[w.id] = w.frame }
                WindowCore.move(w, cocoa: r)
            }
        }
        lastSignature = WindowCore.onScreenIDs()
    }

    /// Puts every window back where it was before Tiles first moved it.
    func restore() {
        guard AX.ensureTrusted() else { return }
        for w in WindowCore.windows() { if let r = original[w.id] { AX.setFrame(w.el, r, app: w.app) } }
        original = [:]
    }

    func setAuto(_ on: Bool) {
        poll?.invalidate()
        poll = nil
        if let o = spaceObserver { NSWorkspace.shared.notificationCenter.removeObserver(o) }
        spaceObserver = nil
        auto = on && AX.ensureTrusted()
        defer { onChange?() }
        guard auto else { return }
        tile()
        // Watching the on-screen window ids is cheap (no AX calls) and catches opens, closes,
        // minimise, hide and Space switches without per-app observers.
        poll = Timer.scheduledTimer(withTimeInterval: 0.35, repeats: true) { [weak self] _ in
            guard let self else { return }
            let sig = WindowCore.onScreenIDs()
            if sig != self.lastSignature { self.lastSignature = sig; self.tile() }
        }
        poll?.tolerance = 0.1
        spaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in self?.tile() }
    }

    func setLayout(_ l: Tiling) {
        layout = l
        tile()
        onChange?()
    }

    func promote() {
        guard let w = WindowCore.focused() else { return }
        order.removeAll { $0 == w.id }
        order.insert(w.id, at: 0)
        tile()
    }

    func resizeMaster(by d: CGFloat) {
        ratio = min(max(ratio + d, 0.15), 0.85)
        tile()
    }

    func toggleFloat() {
        guard let w = WindowCore.focused() else { return }
        let name = w.appName.lowercased()
        if floating.contains(name) { floating.remove(name) } else { floating.insert(name) }
        if auto { tile() }
        onChange?()
    }

    // MARK: focus and swap

    private func neighbor(_ dir: String) -> (Win, Win)? {
        guard AX.ensureTrusted(), let cur = WindowCore.focused() else { return nil }
        let others = WindowCore.windows().filter { $0.id != cur.id && !AX.bool($0.el, kAXMinimizedAttribute) }
        guard let i = nearest(of: Geo.flip(cur.frame), in: dir, among: others.map { Geo.flip($0.frame) }) else { return nil }
        return (cur, others[i])
    }

    func focus(_ dir: String) {
        if let (_, to) = neighbor(dir) { WindowCore.raise(to) }
    }

    func swap(_ dir: String) {
        guard let (a, b) = neighbor(dir) else { return }
        if let i = order.firstIndex(of: a.id), let j = order.firstIndex(of: b.id) { order.swapAt(i, j) }
        AX.setFrame(a.el, b.frame, app: a.app)
        AX.setFrame(b.el, a.frame, app: b.app)
        WindowCore.raise(a)
    }

    // MARK: actions

    /// One small language shared by hotkeys, the menu and tiles:// URLs:
    /// tile · restore · layout <name> · auto on|off|toggle · focus|swap left|right|up|down ·
    /// promote · grow · shrink · float
    @discardableResult func perform(_ action: String) -> Bool {
        let w = action.lowercased().split(whereSeparator: { $0 == " " || $0 == "/" }).map(String.init)
        guard let verb = w.first else { return false }
        let arg = w.dropFirst().first ?? ""
        switch verb {
        case "tile": tile()
        case "restore": restore()
        case "layout": guard let l = Tiling(key: arg) else { return false }; setLayout(l)
        case "auto": setAuto(arg == "on" ? true : arg == "off" ? false : !auto)
        case "focus" where Tiler.directions.contains(arg): focus(arg)
        case "swap" where Tiler.directions.contains(arg): swap(arg)
        case "promote": promote()
        case "grow": resizeMaster(by: 0.05)
        case "shrink": resizeMaster(by: -0.05)
        case "float": toggleFloat()
        default: return false
        }
        return true
    }

    static let directions: Set<String> = ["left", "right", "up", "down"]
}
