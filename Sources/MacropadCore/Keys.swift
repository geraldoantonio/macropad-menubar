/// Name tables: HID keyboard usages, modifier bits, consumer (media) codes and mouse actions.
///
/// Ported from the `macropad` CLI (nacif-software/vibe-coder-keyboard, `keys.py`) so both tools
/// read and write the same action syntax. Canonical names come first; aliases map onto them.
/// Order matters: when formatting, the first name with a given value wins.
public enum Keys {
    /// HID keyboard modifier bitmask, in the order macOS displays them (⌃⌥⇧⌘).
    public static let modifiers: [(name: String, bit: UInt8)] = [
        ("ctrl", 0x01), ("opt", 0x04), ("shift", 0x02), ("cmd", 0x08),
        ("rctrl", 0x10), ("ropt", 0x40), ("rshift", 0x20), ("rcmd", 0x80),
    ]

    public static let modifierAliases: [String: String] = [
        "control": "ctrl", "option": "opt", "alt": "opt",
        "command": "cmd", "win": "cmd", "super": "cmd", "meta": "cmd", "gui": "cmd",
        "rcontrol": "rctrl", "roption": "ropt", "ralt": "ropt", "rcommand": "rcmd", "rwin": "rcmd",
    ]

    /// HID usage page 0x07 (keyboard).
    public static let keys: [(name: String, code: UInt8)] = {
        var table: [(String, UInt8)] = []
        for i in 0..<26 { table.append((String(UnicodeScalar(UInt8(97 + i))), UInt8(0x04 + i))) }
        for n in 1...9 { table.append((String(n), UInt8(0x1E + n - 1))) }
        table += [
            ("0", 0x27), ("enter", 0x28), ("esc", 0x29), ("backspace", 0x2A), ("tab", 0x2B),
            ("space", 0x2C), ("minus", 0x2D), ("equal", 0x2E), ("lbracket", 0x2F),
            ("rbracket", 0x30), ("backslash", 0x31), ("semicolon", 0x33), ("quote", 0x34),
            ("grave", 0x35), ("comma", 0x36), ("period", 0x37), ("slash", 0x38), ("capslock", 0x39),
        ]
        for n in 1...12 { table.append(("f\(n)", UInt8(0x3A + n - 1))) }
        table += [
            ("printscreen", 0x46), ("scrolllock", 0x47), ("pause", 0x48), ("insert", 0x49),
            ("home", 0x4A), ("pageup", 0x4B), ("forward-delete", 0x4C), ("end", 0x4D),
            ("pagedown", 0x4E), ("right", 0x4F), ("left", 0x50), ("down", 0x51), ("up", 0x52),
            ("numlock", 0x53), ("kp-slash", 0x54), ("kp-asterisk", 0x55), ("kp-minus", 0x56),
            ("kp-plus", 0x57), ("kp-enter", 0x58),
        ]
        for n in 1...9 { table.append(("kp-\(n)", UInt8(0x59 + n - 1))) }
        table += [("kp-0", 0x62), ("kp-period", 0x63), ("menu", 0x65), ("kp-equal", 0x67)]
        for n in 13...24 { table.append(("f\(n)", UInt8(0x68 + n - 13))) }
        return table
    }()

    public static let keyAliases: [String: String] = [
        "return": "enter", "escape": "esc", "spacebar": "space",
        "-": "minus", "=": "equal", "[": "lbracket", "]": "rbracket", "\\": "backslash",
        ";": "semicolon", "'": "quote", "`": "grave", "backtick": "grave",
        ".": "period", "dot": "period", "/": "slash",
        "pgup": "pageup", "pgdn": "pagedown", "ins": "insert", "prtsc": "printscreen",
        "arrow-left": "left", "arrow-right": "right", "arrow-up": "up", "arrow-down": "down",
    ]

    /// Keys the vendor's Windows tool does not offer; the firmware may or may not emit them.
    public static let unverifiedKeys: Set<String> =
        Set((13...24).map { "f\($0)" }).union(["kp-enter", "kp-equal"])

    /// Names that mean different keys on macOS and PC keyboards.
    public static let ambiguous: [String: [String]] = [
        "delete": ["backspace", "forward-delete"],
        "del": ["backspace", "forward-delete"],
    ]

    /// HID usage page 0x0C (consumer).
    public static let media: [(name: String, code: UInt16)] = [
        ("play", 0xCD), ("next", 0xB5), ("prev", 0xB6), ("stop", 0xB7), ("mute", 0xE2),
        ("volume-up", 0xE9), ("volume-down", 0xEA), ("brightness-up", 0x6F), ("brightness-down", 0x70),
    ]

    public static let mediaAliases: [String: String] = [
        "play-pause": "play", "previous": "prev", "vol-up": "volume-up", "vol-down": "volume-down",
    ]

    /// name -> (button bits, wheel delta). Buttons: left=1, right=2, middle=4.
    public static let mouse: [(name: String, buttons: UInt8, wheel: Int8)] = [
        ("click", 0x01, 0), ("right-click", 0x02, 0), ("middle-click", 0x04, 0),
        ("scroll-up", 0, 1), ("scroll-down", 0, -1),
    ]

    public static let mouseAliases: [String: String] = [
        "left-click": "click", "wheel-up": "scroll-up", "wheel-down": "scroll-down",
    ]

    // MARK: Lookups

    static let modifierBits = Dictionary(uniqueKeysWithValues: modifiers.map { ($0.name, $0.bit) })
    static let keyCodes = Dictionary(keys.map { ($0.name, $0.code) }, uniquingKeysWith: { first, _ in first })
    static let mediaCodes = Dictionary(uniqueKeysWithValues: media.map { ($0.name, $0.code) })

    public static func keyName(for code: UInt8) -> String? { keys.first { $0.code == code }?.name }
    public static func mediaName(for code: UInt16) -> String? { media.first { $0.code == code }?.name }
    public static func mouseName(buttons: UInt8, wheel: Int8) -> String? {
        mouse.first { $0.buttons == buttons && $0.wheel == wheel }?.name
    }

    /// Every name the parser accepts, for suggestions.
    public static let allNames: [String] =
        modifiers.map(\.name) + Array(modifierAliases.keys) + keys.map(\.name) + Array(keyAliases.keys)
        + media.map(\.name) + Array(mediaAliases.keys) + mouse.map(\.name) + Array(mouseAliases.keys)
}
