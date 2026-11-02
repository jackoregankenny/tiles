import AppKit
import ApplicationServices

// Window access: Accessibility to move and resize, CGWindowList to see what is on the current Space. No SIP changes, no scripting additions; the only
// private call is the AX element -> window id lookup that every macOS window manager uses.

@_silgen_name("_AXUIElementGetWindow")
private func _AXUIElementGetWindow(_ el: AXUIElement, _ id: UnsafeMutablePointer<CGWindowID>) -> AXError

enum AX {
    static func attr(_ el: AXUIElement, _ name: String) -> CFTypeRef? {
        var v: CFTypeRef?
        return AXUIElementCopyAttributeValue(el, name as CFString, &v) == .success ? v : nil
    }
    static func set(_ el: AXUIElement, _ name: String, _ v: CFTypeRef) {
        AXUIElementSetAttributeValue(el, name as CFString, v)
    }
    static func bool(_ el: AXUIElement, _ name: String) -> Bool { (attr(el, name) as? Bool) ?? false }
    static func string(_ el: AXUIElement, _ name: String) -> String? { attr(el, name) as? String }

    static func frame(_ el: AXUIElement) -> CGRect? {
        guard let p = attr(el, kAXPositionAttribute), let s = attr(el, kAXSizeAttribute),
              CFGetTypeID(p) == AXValueGetTypeID(), CFGetTypeID(s) == AXValueGetTypeID() else { return nil }
        var origin = CGPoint.zero, size = CGSize.zero
        AXValueGetValue(p as! AXValue, .cgPoint, &origin)
        AXValueGetValue(s as! AXValue, .cgSize, &size)
        return CGRect(origin: origin, size: size)
    }

    /// Size, move, size again: a window that grows before it moves can be clamped by the screen edge.
    static func setFrame(_ el: AXUIElement, _ r: CGRect, app: AXUIElement? = nil) {
        // Apps with AXEnhancedUserInterface on (Chrome, Electron with a11y) animate every change; turn it off briefly.
        let enhanced = app.map { bool($0, "AXEnhancedUserInterface") } ?? false
        if enhanced, let app { set(app, "AXEnhancedUserInterface", kCFBooleanFalse) }
        var origin = r.origin, size = r.size
        if let sv = AXValueCreate(.cgSize, &size), let pv = AXValueCreate(.cgPoint, &origin) {
            set(el, kAXSizeAttribute, sv)
            set(el, kAXPositionAttribute, pv)
            set(el, kAXSizeAttribute, sv)
        }
        if enhanced, let app { set(app, "AXEnhancedUserInterface", kCFBooleanTrue) }
    }

    static func windowID(_ el: AXUIElement) -> CGWindowID? {
        var id: CGWindowID = 0
        return _AXUIElementGetWindow(el, &id) == .success ? id : nil
    }

    static func app(_ pid: pid_t) -> AXUIElement {
        let el = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(el, 0.3)   // a hung app must not hang us
        return el
    }

    private static var asked = false
    /// True when we may control other apps. The first time it is false, shows the system prompt.
    @discardableResult static func ensureTrusted() -> Bool {
        if AXIsProcessTrusted() { return true }
        if !asked {
            asked = true
            let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            AXIsProcessTrustedWithOptions(opts)
        }
        return false
    }
}

/// Cocoa uses a bottom-left origin on the primary screen; AX and CoreGraphics use top-left.
enum Geo {
    static var primaryHeight: CGFloat { NSScreen.screens.first?.frame.height ?? 0 }
    static func flip(_ r: CGRect) -> CGRect {
        CGRect(x: r.minX, y: primaryHeight - r.maxY, width: r.width, height: r.height)
    }
    static func screen(containing axRect: CGRect) -> NSScreen? {
        let c = flip(axRect)
        let mid = NSPoint(x: c.midX, y: c.midY)
        return NSScreen.screens.first { $0.frame.contains(mid) }
            ?? NSScreen.screens.max { $0.frame.intersection(c).area < $1.frame.intersection(c).area }
    }
}

extension CGRect {
    var area: CGFloat { isNull ? 0 : width * height }
    func near(_ o: CGRect, _ tol: CGFloat = 3) -> Bool {
        abs(minX - o.minX) <= tol && abs(minY - o.minY) <= tol && abs(width - o.width) <= tol && abs(height - o.height) <= tol
    }
}

/// Rectangle math in Cocoa coordinates.
enum Rects {
    /// A region of `a`; x/w are fractions from the left, y/h fractions from the top.
    static func part(_ a: CGRect, x: CGFloat, w: CGFloat, y: CGFloat = 0, h: CGFloat = 1) -> CGRect {
        CGRect(x: a.minX + a.width * x, y: a.maxY - a.height * (y + h), width: a.width * w, height: a.height * h)
    }
    /// Callers pass an area already inset by gap/2; insetting each tile by gap/2 gives equal gaps everywhere.
    static func withGaps(_ r: CGRect, _ gap: CGFloat) -> CGRect { r.insetBy(dx: gap / 2, dy: gap / 2) }
}

enum WindowCore {
    struct Win {
        let el: AXUIElement
        let app: AXUIElement
        let id: CGWindowID
        let pid: pid_t
        let appName: String
        var frame: CGRect   // AX coordinates
    }

    /// Normal windows on the current Space, front to back.
    static func windows() -> [Win] {
        guard let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return [] }
        let me = getpid()
        var apps: [pid_t: (AXUIElement, [CGWindowID: AXUIElement])] = [:]
        var out: [Win] = []
        for w in info {
            guard (w[kCGWindowLayer as String] as? Int) == 0,
                  let pid = w[kCGWindowOwnerPID as String] as? pid_t, pid != me,
                  let id = w[kCGWindowNumber as String] as? CGWindowID,
                  let b = w[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: b), bounds.width >= 100, bounds.height >= 60
            else { continue }
            if apps[pid] == nil {
                let app = AX.app(pid)
                var map: [CGWindowID: AXUIElement] = [:]
                for el in (AX.attr(app, kAXWindowsAttribute) as? [AXUIElement]) ?? [] {
                    if let wid = AX.windowID(el) { map[wid] = el }
                }
                apps[pid] = (app, map)
            }
            guard let (app, map) = apps[pid], let el = map[id] else { continue }
            out.append(Win(el: el, app: app, id: id, pid: pid, appName: w[kCGWindowOwnerName as String] as? String ?? "",
                           frame: bounds))
        }
        return out
    }

    /// Ids of normal on-screen windows, without any AX calls. Cheap enough to poll.
    static func onScreenIDs() -> [CGWindowID] {
        guard let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return [] }
        let me = getpid()
        return info.compactMap { w in
            guard (w[kCGWindowLayer as String] as? Int) == 0, (w[kCGWindowOwnerPID as String] as? pid_t) != me else { return nil }
            return w[kCGWindowNumber as String] as? CGWindowID
        }.sorted()
    }

    static func focused() -> Win? {
        guard let front = NSWorkspace.shared.frontmostApplication else { return nil }
        let app = AX.app(front.processIdentifier)
        guard let v = AX.attr(app, kAXFocusedWindowAttribute), CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }
        let el = v as! AXUIElement
        guard let id = AX.windowID(el), let frame = AX.frame(el) else { return nil }
        return Win(el: el, app: app, id: id, pid: front.processIdentifier, appName: front.localizedName ?? "", frame: frame)
    }

    static func move(_ w: Win, cocoa r: CGRect) { AX.setFrame(w.el, Geo.flip(r.integral), app: w.app) }

    static func raise(_ w: Win) {
        AX.set(w.el, kAXMainAttribute, kCFBooleanTrue)
        AXUIElementPerformAction(w.el, kAXRaiseAction as CFString)
        // Setting AXFrontmost works from a background app, where NSRunningApplication.activate may be refused.
        AX.set(w.app, kAXFrontmostAttribute, kCFBooleanTrue)
    }
}
