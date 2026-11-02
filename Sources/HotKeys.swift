import AppKit
import Carbon.HIToolbox

/// Global hotkeys through Carbon: no Accessibility or Input Monitoring permission needed.
final class HotKeys {
    private static var actions: [UInt32: () -> Void] = [:]
    private static var installed = false
    private var refs: [EventHotKeyRef] = []
    private var next: UInt32 = 1

    init() {
        guard !HotKeys.installed else { return }
        HotKeys.installed = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var id = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &id)
            if let action = HotKeys.actions[id.id] { DispatchQueue.main.async(execute: action) }
            return noErr
        }, 1, &spec, nil, nil)
    }

    @discardableResult func register(_ combo: String, _ action: @escaping () -> Void) -> Bool {
        guard let (key, mods) = HotKeys.parse(combo) else { return false }
        var ref: EventHotKeyRef?
        let id = EventHotKeyID(signature: OSType(0x5259_4654), id: next)
        guard RegisterEventHotKey(UInt32(key), UInt32(mods), id, GetApplicationEventTarget(), 0, &ref) == noErr, let ref else { return false }
        HotKeys.actions[next] = action
        refs.append(ref)
        next += 1
        return true
    }

    func removeAll() {
        refs.forEach { UnregisterEventHotKey($0) }
        refs = []
        HotKeys.actions = [:]
    }

    static let keys: [String: Int] = [
        "a": kVK_ANSI_A, "b": kVK_ANSI_B, "c": kVK_ANSI_C, "d": kVK_ANSI_D, "e": kVK_ANSI_E, "f": kVK_ANSI_F, "g": kVK_ANSI_G,
        "h": kVK_ANSI_H, "i": kVK_ANSI_I, "j": kVK_ANSI_J, "k": kVK_ANSI_K, "l": kVK_ANSI_L, "m": kVK_ANSI_M, "n": kVK_ANSI_N,
        "o": kVK_ANSI_O, "p": kVK_ANSI_P, "q": kVK_ANSI_Q, "r": kVK_ANSI_R, "s": kVK_ANSI_S, "t": kVK_ANSI_T, "u": kVK_ANSI_U,
        "v": kVK_ANSI_V, "w": kVK_ANSI_W, "x": kVK_ANSI_X, "y": kVK_ANSI_Y, "z": kVK_ANSI_Z,
        "0": kVK_ANSI_0, "1": kVK_ANSI_1, "2": kVK_ANSI_2, "3": kVK_ANSI_3, "4": kVK_ANSI_4, "5": kVK_ANSI_5, "6": kVK_ANSI_6,
        "7": kVK_ANSI_7, "8": kVK_ANSI_8, "9": kVK_ANSI_9, "minus": kVK_ANSI_Minus, "equal": kVK_ANSI_Equal,
        "space": kVK_Space, "return": kVK_Return, "enter": kVK_Return, "tab": kVK_Tab, "escape": kVK_Escape,
        "delete": kVK_Delete, "backspace": kVK_Delete,
        "left": kVK_LeftArrow, "right": kVK_RightArrow, "up": kVK_UpArrow, "down": kVK_DownArrow,
        "comma": kVK_ANSI_Comma, "period": kVK_ANSI_Period, "slash": kVK_ANSI_Slash, "semicolon": kVK_ANSI_Semicolon,
        "f1": kVK_F1, "f2": kVK_F2, "f3": kVK_F3, "f4": kVK_F4, "f5": kVK_F5, "f6": kVK_F6,
    ]

    static func parse(_ combo: String) -> (key: Int, mods: Int)? {
        var mods = 0, key: Int?
        for part in combo.lowercased().split(separator: "+").map({ $0.trimmingCharacters(in: .whitespaces) }) {
            switch part {
            case "cmd", "command", "⌘": mods |= cmdKey
            case "opt", "option", "alt", "⌥": mods |= optionKey
            case "ctrl", "control", "⌃": mods |= controlKey
            case "shift", "⇧": mods |= shiftKey
            default: key = keys[part]; if key == nil { return nil }
            }
        }
        return key.map { ($0, mods) }
    }

    /// Defaults with the user's entries on top; mapping a combo to "none" (or "") turns that default off.
    static func merged(_ defaults: [String: String], _ user: [String: String]?) -> [String: String] {
        var out = defaults
        for (combo, action) in user ?? [:] {
            let a = action.trimmingCharacters(in: .whitespaces)
            // The same physical combo can be spelled differently ("opt" / "alt"); compare parsed keys.
            if let p = parse(combo) { out = out.filter { parse($0.key).map { $0 != p } ?? true } }
            if !(a.isEmpty || a.lowercased() == "none") { out[combo] = a }
        }
        return out
    }

    /// "ctrl+opt+left" -> "⌃⌥←"
    static func symbols(_ combo: String) -> String {
        let names: [String: String] = ["left": "←", "right": "→", "up": "↑", "down": "↓", "return": "↩", "enter": "↩",
                                       "space": "Space", "minus": "-", "equal": "=", "tab": "⇥", "escape": "⎋",
                                       "delete": "⌫", "backspace": "⌫"]
        var mods = "", key = ""
        let parts = Set(combo.lowercased().split(separator: "+").map(String.init))
        for (m, s) in [("ctrl", "⌃"), ("control", "⌃"), ("opt", "⌥"), ("alt", "⌥"), ("option", "⌥"), ("shift", "⇧"),
                       ("cmd", "⌘"), ("command", "⌘")] where parts.contains(m) && !mods.contains(s) { mods += s }
        for p in parts where keys[p] != nil { key = names[p] ?? p.uppercased() }
        return mods + key
    }
}
