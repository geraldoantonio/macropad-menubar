import Foundation

/// Something the app does when a pad key sends its trigger shortcut.
///
/// The pad itself can only send keystrokes, so a "program" key is bound to an otherwise unused
/// shortcut (the trigger, e.g. ⌃⌥⇧⌘1); the app registers that shortcut globally and runs the
/// command when it arrives.
public struct Command: Codable, Equatable, Hashable, Sendable {
    public enum Kind: String, Codable, CaseIterable, Sendable {
        case openApp = "app"
        case openURL = "url"
        case shell = "shell"
        case shortcut = "shortcut"
    }

    public var kind: Kind
    /// App path, URL, shell script or Shortcuts name, depending on `kind`.
    public var value: String

    public init(kind: Kind, value: String) {
        self.kind = kind
        self.value = value
    }

    /// Short label for the pad drawing.
    public var label: String {
        switch kind {
        case .openApp:
            return URL(fileURLWithPath: value).deletingPathExtension().lastPathComponent
        case .openURL:
            return URL(string: value)?.host ?? value
        case .shell:
            return "Script"
        case .shortcut:
            return value
        }
    }

    public var isValid: Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        switch kind {
        case .openURL:
            guard let url = URL(string: trimmed), let scheme = url.scheme else { return false }
            return !scheme.isEmpty
        default:
            return !trimmed.isEmpty
        }
    }
}

/// "When this app is in front, put this preset on the pad."
public struct AutoRule: Codable, Equatable, Hashable, Identifiable, Sendable {
    public var bundleID: String
    public var appName: String
    /// `Preset.id` of the preset to apply.
    public var preset: String

    public var id: String { bundleID }

    public init(bundleID: String, appName: String, preset: String) {
        self.bundleID = bundleID
        self.appName = appName
        self.preset = preset
    }
}

/// The app's own settings, kept apart from the CLI's layout file so the CLI keeps reading it.
/// Stored as JSON in `~/.config/macropad/app.json`.
public struct AppConfig: Codable, Equatable, Sendable {
    /// Trigger shortcut (canonical action text) -> what to run.
    public var commands: [String: Command] = [:]
    public var autoSwitch = false
    public var rules: [AutoRule] = []
    /// Preset for apps without a rule; nil leaves the pad as it is.
    public var defaultPreset: String?

    public init() {}

    public static var defaultURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/macropad/app.json")
    }

    public static func load(from url: URL = defaultURL) -> AppConfig {
        guard let data = try? Data(contentsOf: url) else { return AppConfig() }
        return (try? JSONDecoder().decode(AppConfig.self, from: data)) ?? AppConfig()
    }

    public func save(to url: URL = defaultURL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: url, options: .atomic)
    }

    public func rule(for bundleID: String) -> AutoRule? {
        rules.first { $0.bundleID == bundleID }
    }

    /// The preset id to apply when `bundleID` comes to the front (nil = leave the pad alone).
    public func presetID(for bundleID: String) -> String? {
        rule(for: bundleID)?.preset ?? defaultPreset
    }

    public mutating func setRule(_ rule: AutoRule) {
        if let i = rules.firstIndex(where: { $0.bundleID == rule.bundleID }) { rules[i] = rule } else { rules.append(rule) }
    }

    public mutating func removeRule(bundleID: String) {
        rules.removeAll { $0.bundleID == bundleID }
    }

    // MARK: Triggers

    /// Shortcuts the app hands out as triggers: Hyper (⌃⌥⇧⌘) + a digit or letter.
    /// Nothing on macOS uses four-modifier combos by default.
    public static let triggerPool: [String] = {
        let keys = ["1", "2", "3", "4", "5", "6", "7", "8", "9", "0"] + (97...122).map { String(UnicodeScalar(UInt8($0))) }
        return keys.map { "ctrl+opt+shift+cmd+\($0)" }
    }()

    /// The command bound to `actionText`, if it is one of our triggers.
    public func command(forActionText actionText: String?) -> Command? {
        guard let text = actionText, let action = try? Action(parsing: text) else { return nil }
        return commands[action.canonical]
    }

    /// A trigger no command uses yet, skipping the ones in `reserved` (e.g. still on the pad).
    public func freeTrigger(reserved: Set<String> = []) -> String? {
        AppConfig.triggerPool.first { commands[$0] == nil && !reserved.contains($0) }
    }

    /// Drops commands whose trigger appears in none of `layouts` (current layout + presets).
    public mutating func pruneCommands(keeping layouts: [Layout]) {
        var used = Set<String>()
        for layout in layouts {
            for slots in layout.layers.values {
                for text in slots.values {
                    if let action = try? Action(parsing: text) { used.insert(action.canonical) }
                }
            }
        }
        commands = commands.filter { used.contains($0.key) }
    }
}
