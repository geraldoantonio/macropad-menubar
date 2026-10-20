import Foundation

/// App languages. Portuguese is the source language: its strings are the lookup keys.
public enum Language: String, CaseIterable, Codable, Sendable, Identifiable {
    case pt, en, es

    public var id: String { rawValue }

    /// The language's own name, for the picker.
    public var nativeName: String {
        switch self {
        case .pt: "Português"
        case .en: "English"
        case .es: "Español"
        }
    }

    /// The best match for the macOS preferred languages; English for anything else.
    public static var system: Language {
        for identifier in Locale.preferredLanguages {
            let code = identifier.lowercased()
            if code.hasPrefix("pt") { return .pt }
            if code.hasPrefix("es") { return .es }
            if code.hasPrefix("en") { return .en }
        }
        return .en
    }
}

public enum L10n {
    /// Chosen in the app's settings; nil follows the system.
    public static var override: Language?

    public static var current: Language { override ?? Language.system }

    static func table(_ language: Language) -> [String: String]? {
        switch language {
        case .pt: nil
        case .en: L10nStrings.en
        case .es: L10nStrings.es
        }
    }

    /// Every key with a translation, for tests.
    public static var keys: (en: Set<String>, es: Set<String>) {
        (Set(L10nStrings.en.keys), Set(L10nStrings.es.keys))
    }

    public static func translate(_ key: String, _ language: Language, _ args: [String]) -> String {
        let template = table(language)?[key] ?? key
        guard !args.isEmpty else { return template }
        // Fill each %@ in order (no String(format:), so stray % in arguments can't crash).
        var result = ""
        var remaining = args[...]
        var rest = Substring(template)
        while let range = rest.range(of: "%@") {
            result += rest[..<range.lowerBound]
            result += remaining.popFirst() ?? ""
            rest = rest[range.upperBound...]
        }
        return result + rest
    }
}

/// Localized text: `L("Gravar no pad")`, `L("Tecla %@", "3")`.
/// The key is the Portuguese text; `%@` marks each argument.
public func L(_ key: String, _ args: String...) -> String {
    L10n.translate(key, L10n.current, args)
}
