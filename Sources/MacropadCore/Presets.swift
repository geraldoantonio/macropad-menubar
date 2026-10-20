import Foundation

public struct Preset: Identifiable, Equatable, Sendable {
    public var name: String
    public var layout: Layout
    public var builtIn: Bool
    /// For user presets, the file it lives in.
    public var url: URL?

    public var id: String { (builtIn ? "builtin:" : "user:") + name }

    public init(name: String, layout: Layout, builtIn: Bool = false, url: URL? = nil) {
        self.name = name
        self.layout = layout
        self.builtIn = builtIn
        self.url = url
    }
}

extension Preset {
    /// "Nacif's Vibe Coder Keyboard Keys" — driving Claude Code with dictation (from the
    /// vibe-coder-keyboard repo, MIT). The knob opens the model picker and sets the effort.
    public static let vibeCoder = Preset(name: "Vibe Coder (Claude Code)", layout: Layout(layers: [1: [
        .key1: "esc", .key2: "pageup", .key3: "up",
        .key4: "space", .key5: "pagedown", .key6: "down",
        .knobLeft: "opt+p, left", .knobPress: "enter", .knobRight: "opt+p, right",
    ]]), builtIn: true)

    public static let editing = Preset(name: "Edição", layout: Layout(layers: [1: [
        .key1: "cmd+c", .key2: "cmd+v", .key3: "shift+cmd+4",
        .key4: "cmd+z", .key5: "shift+cmd+z", .key6: "cmd+s",
        .knobLeft: "volume-down", .knobPress: "mute", .knobRight: "volume-up",
    ]]), builtIn: true)

    public static let media = Preset(name: "Mídia", layout: Layout(layers: [1: [
        .key1: "prev", .key2: "play", .key3: "next",
        .key4: "brightness-down", .key5: "mute", .key6: "brightness-up",
        .knobLeft: "volume-down", .knobPress: "play", .knobRight: "volume-up",
    ]]), builtIn: true)

    public static let browsing = Preset(name: "Navegação", layout: Layout(layers: [1: [
        .key1: "cmd+lbracket", .key2: "cmd+r", .key3: "cmd+rbracket",
        .key4: "ctrl+shift+tab", .key5: "cmd+t", .key6: "ctrl+tab",
        .knobLeft: "scroll-up", .knobPress: "cmd+w", .knobRight: "scroll-down",
    ]]), builtIn: true)

    public static let builtIns: [Preset] = [vibeCoder, editing, media, browsing]
}

/// User presets: one layout YAML per file in `~/.config/macropad/presets/`.
public struct PresetStore: Sendable {
    public let directory: URL

    public init(directory: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/macropad/presets")) {
        self.directory = directory
    }

    public func userPresets() -> [Preset] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return files
            .filter { ["yaml", "yml"].contains($0.pathExtension.lowercased()) }
            .compactMap { url in
                guard let layout = try? Layout.load(from: url) else { return nil }
                return Preset(name: url.deletingPathExtension().lastPathComponent, layout: layout, url: url)
            }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    @discardableResult
    public func save(_ layout: Layout, named name: String) throws -> URL {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        guard !clean.isEmpty, !clean.hasPrefix(".") else { throw LayoutError(["Nome de preset inválido"]) }
        let url = directory.appendingPathComponent(clean).appendingPathExtension("yaml")
        try layout.save(to: url)
        return url
    }

    public func delete(_ preset: Preset) throws {
        guard let url = preset.url else { return }
        try FileManager.default.removeItem(at: url)
    }
}
