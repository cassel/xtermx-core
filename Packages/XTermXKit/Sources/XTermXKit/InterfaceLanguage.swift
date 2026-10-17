import Foundation

public enum InterfaceLanguage: String, CaseIterable, Identifiable, Sendable {
    case system, english = "en", portuguese = "pt-BR", spanish = "es", chinese = "zh-Hans"
    public static let preferenceKey = "xtermx.interface.language"
    public var id: String { rawValue }
    public var nativeName: String {
        switch self {
        case .system: "System language"
        case .english: "English"
        case .portuguese: "Português (Brasil)"
        case .spanish: "Español"
        case .chinese: "简体中文"
        }
    }
    public static var current: Self { Self(rawValue: UserDefaults.standard.string(forKey: preferenceKey) ?? "") ?? .system }
    public func resolved(preferred: [String] = Locale.preferredLanguages) -> Self {
        guard self == .system else { return self }
        for language in preferred {
            let prefix = language.lowercased().replacingOccurrences(of: "_", with: "-")
            if prefix == "en" || prefix.hasPrefix("en-") { return .english }
            if prefix == "pt" || prefix.hasPrefix("pt-") { return .portuguese }
            if prefix == "es" || prefix.hasPrefix("es-") { return .spanish }
            if prefix == "zh" || prefix.hasPrefix("zh-") { return .chinese }
        }
        return .english
    }
    public var locale: Locale { Locale(identifier: resolved().rawValue) }
    public func bundle(in bundle: Bundle = .main) -> Bundle {
        guard let path = bundle.path(forResource: resolved().rawValue, ofType: "lproj"), let localized = Bundle(path: path) else { return bundle }
        return localized
    }
    public func text(_ key: String, in bundle: Bundle = .main) -> String {
        self.bundle(in: bundle).localizedString(forKey: key, value: key, table: "Localizable")
    }
}
