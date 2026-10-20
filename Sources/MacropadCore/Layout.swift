import Foundation
import Yams

/// The layout file — the local record of what the (write-only) pad holds.
///
/// Same format and default path as the `macropad` CLI, so the app and the CLI share it:
///
///     led: 1                     # optional, 0-2
///     layers:
///       1:
///         key1: cmd+c
///         key4: cmd+a, cmd+c
///         knob-right: volume-up
public struct Layout: Equatable, Sendable {
    public var led: Int?
    public var layers: [Int: [Slot: String]]

    public init(led: Int? = nil, layers: [Int: [Slot: String]] = [:]) {
        self.led = led
        self.layers = layers
    }

    public func text(layer: Int, slot: Slot) -> String? { layers[layer]?[slot] }

    public func action(layer: Int, slot: Slot) -> Action? {
        text(layer: layer, slot: slot).flatMap { try? Action(parsing: $0) }
    }

    /// Stores the canonical form of `actionText`; throws ActionError if it's invalid.
    public mutating func set(layer: Int, slot: Slot, actionText: String) throws {
        let action = try Action(parsing: actionText)
        layers[layer, default: [:]][slot] = action.canonical
    }

    public mutating func clear(layer: Int, slot: Slot) {
        layers[layer]?[slot] = nil
        if layers[layer]?.isEmpty == true { layers[layer] = nil }
    }

    public var isEmpty: Bool { layers.isEmpty && led == nil }

    /// `$MACROPAD_LAYOUT`, else `~/.config/macropad/layout.yaml` (the CLI's default).
    public static var defaultURL: URL {
        if let custom = ProcessInfo.processInfo.environment["MACROPAD_LAYOUT"], !custom.isEmpty {
            return URL(fileURLWithPath: (custom as NSString).expandingTildeInPath)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/macropad/layout.yaml")
    }
}

public struct LayoutError: Error, LocalizedError, Equatable {
    public let problems: [String]
    public init(_ problems: [String]) { self.problems = problems }
    public var errorDescription: String? { problems.joined(separator: "\n") }
}

// MARK: - Reading

extension Layout {
    /// Reads a layout file; a missing file is an empty layout.
    public static func load(from url: URL) throws -> Layout {
        guard FileManager.default.fileExists(atPath: url.path) else { return Layout() }
        let text: String
        do { text = try String(contentsOf: url, encoding: .utf8) } catch {
            throw LayoutError([L("%@: não foi possível ler (%@)", url.path, error.localizedDescription)])
        }
        return try parse(yaml: text, source: url.lastPathComponent)
    }

    public static func parse(yaml text: String, source: String = "layout") throws -> Layout {
        let loaded: Any?
        do { loaded = try Yams.load(yaml: text) } catch {
            throw LayoutError([L("%@: YAML inválido: %@", source, "\(error)")])
        }
        guard let root = loaded else { return Layout() }
        guard let data = root as? [AnyHashable: Any] else {
            throw LayoutError([L("%@: esperado um mapa com 'led' e 'layers'", source)])
        }

        var problems: [String] = []
        for key in data.keys where !["led", "layers"].contains(key as? String ?? "") {
            problems.append(L("%@: chave desconhecida", "\(key)"))
        }

        var led: Int?
        if let raw = data["led"], !(raw is NSNull) {
            if let value = intValue(raw), PadProtocol.ledModes.contains(value) { led = value } else {
                problems.append("led: deve ser 0, 1 ou 2; veio \(raw)")
            }
        }

        var layers: [Int: [Slot: String]] = [:]
        let rawLayers = data["layers"]
        if let rawLayers, !(rawLayers is NSNull), !(rawLayers is [AnyHashable: Any]) {
            problems.append("layers: esperado um mapa de camada -> slots")
        }
        for (rawLayer, rawSlots) in (rawLayers as? [AnyHashable: Any]) ?? [:] {
            guard let layer = intValue(rawLayer), PadProtocol.layers.contains(layer) else {
                problems.append("layers.\(rawLayer): a camada deve ser 1, 2 ou 3")
                continue
            }
            if rawSlots is NSNull { continue }
            guard let slots = rawSlots as? [AnyHashable: Any] else {
                problems.append("layers.\(layer): esperado um mapa de slot -> ação")
                continue
            }
            for (rawSlot, rawText) in slots {
                let where_ = "layers.\(layer).\(rawSlot)"
                guard let name = rawSlot as? String, let slot = Slot(rawValue: name) else {
                    problems.append(L("%@: slot desconhecido", where_))
                    continue
                }
                let text: String
                if let s = rawText as? String { text = s }
                else if !(rawText is Bool), let n = rawText as? Int { text = String(n) }
                else { problems.append(L("%@: a ação deve ser texto", where_)); continue }
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                do { _ = try Action(parsing: trimmed) } catch {
                    problems.append("\(where_): \(error.localizedDescription)")
                    continue
                }
                layers[layer, default: [:]][slot] = trimmed
            }
        }

        if !problems.isEmpty { throw LayoutError(problems.sorted()) }
        return Layout(led: led, layers: layers)
    }

    private static func intValue(_ value: Any) -> Int? {
        if value is Bool { return nil }
        if let n = value as? Int { return n }
        if let s = value as? String { return Int(s) }
        return nil
    }
}

// MARK: - Writing

extension Layout {
    /// YAML in the same shape the CLI writes (`yaml.safe_dump(sort_keys=False)`).
    public var yaml: String {
        var lines: [String] = []
        if let led { lines.append("led: \(led)") }
        let used = layers.keys.sorted().filter { !(layers[$0]?.isEmpty ?? true) }
        if used.isEmpty {
            lines.append("layers: {}")
        } else {
            lines.append("layers:")
            for layer in used {
                lines.append("  \(layer):")
                for slot in Slot.allCases {
                    if let text = layers[layer]?[slot] { lines.append("    \(slot.rawValue): \(Layout.scalar(text))") }
                }
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    public func save(to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try yaml.write(to: url, atomically: true, encoding: .utf8)
    }

    /// Writes `text` plain when YAML reads it back as the same string, single-quoted otherwise.
    static func scalar(_ text: String) -> String {
        if let back = try? Yams.load(yaml: "k: \(text)") as? [String: Any], back["k"] as? String == text,
           !text.contains("\n") {
            return text
        }
        return "'" + text.replacingOccurrences(of: "'", with: "''") + "'"
    }
}
