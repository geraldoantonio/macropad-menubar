import Foundation

/// One keystroke: a modifier bitmask plus a HID key code (0 = no key).
public struct Keystroke: Equatable, Hashable, Sendable {
    public var mods: UInt8
    public var code: UInt8
    public init(mods: UInt8, code: UInt8) { self.mods = mods; self.code = code }
}

/// What a slot does. Syntax (same as the `macropad` CLI):
///
///     combo     cmd+shift+4          any modifiers + at most one regular key
///     sequence  cmd+a, cmd+c         up to `maxSteps` combos, comma separated
///     media     volume-up            alone, no modifiers
///     mouse     ctrl+scroll-up       modifiers allowed, not in a sequence
public enum Action: Equatable, Hashable, Sendable {
    case keys([Keystroke])
    case media(code: UInt16)
    case mouse(buttons: UInt8, wheel: Int8, mods: UInt8)

    public static let maxSteps = 5

    /// Bound to a slot to make it do nothing (not a vendor feature: one empty keystroke).
    public static let empty = Action.keys([Keystroke(mods: 0, code: 0)])
}

public struct ActionError: Error, LocalizedError, Equatable {
    public let message: String
    public let suggestions: [String]
    public init(_ message: String, suggestions: [String] = []) {
        self.message = message
        self.suggestions = suggestions
    }
    public var errorDescription: String? { message }
}

// MARK: - Parsing

extension Action {
    public init(parsing text: String) throws {
        let rawSteps = text.split(separator: ",", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        if rawSteps.allSatisfy(\.isEmpty) { throw ActionError("A ação está vazia") }
        if rawSteps.contains(where: \.isEmpty) {
            throw ActionError("Passo vazio na sequência “\(text.trimmingCharacters(in: .whitespaces))”")
        }
        if rawSteps.count > Action.maxSteps {
            throw ActionError("A sequência tem \(rawSteps.count) passos; o pad toca no máximo \(Action.maxSteps)")
        }

        let parsed = try rawSteps.map(Action.parseStep)
        if parsed.count > 1 {
            var strokes: [Keystroke] = []
            for step in parsed {
                guard case .keys(let s) = step else {
                    throw ActionError("Mídia e mouse não podem fazer parte de uma sequência")
                }
                strokes += s
            }
            self = .keys(strokes)
        } else {
            self = parsed[0]
        }
    }

    /// Parses one step; a keystroke comes back as `.keys([stroke])`.
    private static func parseStep(_ step: String) throws -> Action {
        let tokens = step.split(separator: "+", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        if tokens.contains(where: \.isEmpty) {
            throw ActionError("Nome de tecla vazio em “\(step)” (“+” é separador; use shift+equal)")
        }

        var mods: UInt8 = 0
        var others: [String] = []
        for token in tokens {
            let name = Keys.modifierAliases[token] ?? token
            if let bit = Keys.modifierBits[name] { mods |= bit } else { others.append(token) }
        }

        if others.count > 1 {
            throw ActionError("Só uma tecla comum por passo; “\(step)” tem \(others.joined(separator: ", "))")
        }
        guard let token = others.first else { return .keys([Keystroke(mods: mods, code: 0)]) }

        let mediaName = Keys.mediaAliases[token] ?? token
        if let code = Keys.mediaCodes[mediaName] {
            if mods != 0 { throw ActionError("A tecla de mídia “\(mediaName)” não aceita modificadores") }
            return .media(code: code)
        }

        let mouseName = Keys.mouseAliases[token] ?? token
        if let m = Keys.mouse.first(where: { $0.name == mouseName }) {
            return .mouse(buttons: m.buttons, wheel: m.wheel, mods: mods)
        }

        if let options = Keys.ambiguous[token] {
            throw ActionError("“\(token)” é ambíguo no Mac; use \(options.joined(separator: " ou "))",
                              suggestions: options)
        }

        let keyName = Keys.keyAliases[token] ?? token
        guard let code = Keys.keyCodes[keyName] else {
            let suggestions = closeMatches(token, in: Keys.allNames)
            let hint = suggestions.isEmpty ? "" : "; você quis dizer \(suggestions.joined(separator: " ou "))?"
            throw ActionError("Tecla desconhecida “\(token)”\(hint)", suggestions: suggestions)
        }
        return .keys([Keystroke(mods: mods, code: code)])
    }
}

// MARK: - Formatting

extension Action {
    /// The canonical text form, e.g. `shift+cmd+4` or `cmd+a, cmd+c`.
    public var canonical: String {
        switch self {
        case .media(let code):
            return Keys.mediaName(for: code) ?? String(format: "media-0x%04x", code)
        case .mouse(let buttons, let wheel, let mods):
            let name = Keys.mouseName(buttons: buttons, wheel: wheel) ?? "mouse"
            return (Action.modifierNames(mods) + [name]).joined(separator: "+")
        case .keys(let steps):
            return steps.map { stroke in
                var parts = Action.modifierNames(stroke.mods)
                if stroke.code != 0 { parts.append(Keys.keyName(for: stroke.code) ?? "0x\(String(stroke.code, radix: 16))") }
                return parts.joined(separator: "+")
            }.joined(separator: ", ")
        }
    }

    public static func modifierNames(_ mods: UInt8) -> [String] {
        Keys.modifiers.filter { mods & $0.bit != 0 }.map(\.name)
    }

    /// True for keys the vendor app never offers (the firmware might not send them).
    public var usesUnverifiedKeys: Bool {
        guard case .keys(let steps) = self else { return false }
        return steps.contains { step in
            Keys.keyName(for: step.code).map(Keys.unverifiedKeys.contains) ?? false
        }
    }
}

// MARK: - Suggestions (a small stand-in for Python's difflib.get_close_matches)

func closeMatches(_ word: String, in candidates: [String], limit: Int = 3, cutoff: Double = 0.6) -> [String] {
    let scored = candidates.map { ($0, similarity(word, $0)) }.filter { $0.1 >= cutoff }
    var seen = Set<String>()
    return scored.sorted { $0.1 > $1.1 }.map(\.0).filter { seen.insert($0).inserted }.prefix(limit).map { $0 }
}

private func similarity(_ a: String, _ b: String) -> Double {
    let a = Array(a), b = Array(b)
    if a.isEmpty && b.isEmpty { return 1 }
    var previous = Array(0...b.count)
    for i in 1...max(a.count, 1) where !a.isEmpty {
        var current = [i] + Array(repeating: 0, count: b.count)
        for j in stride(from: 1, through: b.count, by: 1) {
            current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
        }
        previous = current
    }
    let distance = a.isEmpty ? b.count : previous[b.count]
    return 1 - Double(distance) / Double(max(a.count, b.count))
}
