import Foundation

enum ResolvedLanguage: String, CaseIterable {
    case en
    case ko
    case ja

    var nativeName: String {
        switch self {
        case .en:
            return "English"
        case .ko:
            return "한국어"
        case .ja:
            return "日本語"
        }
    }

    var locale: Locale {
        let current = Locale.current
        guard current.language.languageCode?.identifier != rawValue else { return current }
        var components = Locale.Components(locale: current)
        components.languageComponents = Locale.Language.Components(
            languageCode: Locale.LanguageCode(rawValue),
            script: nil,
            region: current.language.region
        )
        return Locale(components: components)
    }
}

enum AppLanguage: String, CaseIterable {
    case system
    case english = "en"
    case korean = "ko"
    case japanese = "ja"

    static let defaultsKey = "appLanguage"

    static func resolved(_ raw: String?) -> AppLanguage {
        guard let raw, let parsed = AppLanguage(rawValue: raw) else { return .system }
        return parsed
    }

    static func stored(_ defaults: UserDefaults = .standard) -> AppLanguage {
        resolved(defaults.string(forKey: defaultsKey))
    }

    static func preferred(from identifiers: [String]) -> ResolvedLanguage {
        for identifier in identifiers {
            guard let code = Locale(identifier: identifier).language.languageCode?.identifier else { continue }
            guard let match = ResolvedLanguage(rawValue: code) else { continue }
            return match
        }
        return .en
    }

    static var systemPreferred: ResolvedLanguage {
        preferred(from: Locale.preferredLanguages)
    }

    var explicit: ResolvedLanguage? {
        switch self {
        case .system:
            return nil
        case .english:
            return .en
        case .korean:
            return .ko
        case .japanese:
            return .ja
        }
    }

    var resolvedLanguage: ResolvedLanguage {
        explicit ?? Self.systemPreferred
    }
}
