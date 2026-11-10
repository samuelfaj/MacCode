import Foundation

/// Language of the app's own interface. `auto` follows the device.
public enum AppLanguage: String, CaseIterable, Sendable, Identifiable {
    case en
    case ptBR = "pt-BR"
    case es
    case fr
    case ar
    case zhHans = "zh-Hans"
    case zhHant = "zh-Hant"

    public var id: String { rawValue }

    /// A label written in the language itself, so the picker is readable
    /// whatever language the app is in.
    public var label: String {
        switch self {
        case .en: return "English"
        case .ptBR: return "Português (Brasil)"
        case .es: return "Español"
        case .fr: return "Français"
        case .ar: return "العربية"
        case .zhHans: return "简体中文"
        case .zhHant: return "繁體中文"
        }
    }

    /// The language the device prefers, first supported one, else English.
    public static func device(preferredLanguages: [String] = Locale.preferredLanguages) -> AppLanguage {
        for candidate in preferredLanguages {
            let tag = candidate.lowercased()
            let primary = tag.split(separator: "-").first.map(String.init) ?? tag
            switch primary {
            case "pt": return .ptBR
            case "en": return .en
            case "es": return .es
            case "fr": return .fr
            case "ar": return .ar
            case "zh":
                return tag.contains("hant") || tag.contains("tw") || tag.contains("hk") ? .zhHant : .zhHans
            default: continue
            }
        }
        return .en
    }
}

/// In-app interface localization. English is the source text: a key is the
/// English string itself, so a missing translation always reads English.
public enum AppLocalization {
    /// Wire/default value that means "follow the device".
    public static let automatic = "auto"

    /// The fixed choice, or `auto`.
    public static var setting: String {
        get { UserDefaults.standard.string(forKey: "app_language") ?? automatic }
        set {
            UserDefaults.standard.set(newValue, forKey: "app_language")
            NotificationCenter.default.post(name: .appLanguageDidChange, object: nil)
        }
    }

    /// The resolved interface language for this moment.
    public static var language: AppLanguage {
        let fixed = setting
        guard fixed != automatic else { return AppLanguage.device() }
        return AppLanguage(rawValue: fixed) ?? .en
    }

    private static let tables: [String: [String: String]] = loadTables()

    private static func loadTables() -> [String: [String: String]] {
        guard let url = Bundle.module.url(forResource: "strings", withExtension: "json", subdirectory: "Localization")
                ?? Bundle.module.url(forResource: "strings", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([String: [String: String]].self, from: data) else {
            return [:]
        }
        return decoded
    }

    /// One translated string. `key` is the English source template; `%1$@`,
    /// `%2$@` are replaced in order by `args`.
    public static func string(_ key: String, _ args: [String]) -> String {
        let language = AppLocalization.language
        let template = language == .en ? key : (tables[language.rawValue]?[key] ?? key)
        guard !args.isEmpty else { return template }
        var result = template
        for (index, value) in args.enumerated() {
            result = result.replacingOccurrences(of: "%\(index + 1)$@", with: value)
        }
        return result
    }

    /// Every string the app can currently translate, for the coverage test.
    public static var translatedKeys: [String: [String: String]] { tables }
}

public extension Notification.Name {
    /// Posted after the interface language changes; surfaces rebuild on it.
    static let appLanguageDidChange = Notification.Name("appLanguageDidChange")
}

/// Translate one user-visible string. The English text is the key.
public func L(_ key: String, _ args: Any...) -> String {
    AppLocalization.string(key, args.map { String(describing: $0) })
}
