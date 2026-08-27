import Foundation

enum AppLanguage: String, CaseIterable, Identifiable {
    case english = "en"
    case simplifiedChinese = "zh-Hans"

    nonisolated var id: String { rawValue }

    nonisolated var locale: Locale {
        Locale(identifier: rawValue)
    }

    nonisolated var title: String {
        switch self {
        case .english: "English"
        case .simplifiedChinese: "Chinese"
        }
    }
}

enum MoniLocalization {
    nonisolated static let preferenceKey = "appLanguage"

    nonisolated static var sharedDefaults: UserDefaults? {
        UserDefaults(suiteName: MoniWidgetStorage.appGroupIdentifier)
    }

    nonisolated static var currentLanguage: AppLanguage {
        let rawValue = UserDefaults.standard.string(forKey: preferenceKey)
            ?? sharedDefaults?.string(forKey: preferenceKey)
            ?? AppLanguage.english.rawValue
        return AppLanguage(rawValue: rawValue) ?? .english
    }

    nonisolated static func setLanguage(_ language: AppLanguage) {
        UserDefaults.standard.set(language.rawValue, forKey: preferenceKey)
        sharedDefaults?.set(language.rawValue, forKey: preferenceKey)
    }

    nonisolated static func string(_ key: String, language: AppLanguage? = nil) -> String {
        let selectedLanguage = language ?? currentLanguage
        guard selectedLanguage != .english,
              let path = Bundle.main.path(forResource: selectedLanguage.rawValue, ofType: "lproj"),
              let bundle = Bundle(path: path)
        else {
            return key
        }
        return bundle.localizedString(forKey: key, value: key, table: nil)
    }

    nonisolated static func format(_ key: String, _ arguments: CVarArg...) -> String {
        let language = currentLanguage
        return String(
            format: string(key, language: language),
            locale: language.locale,
            arguments: arguments
        )
    }

    nonisolated static func compactNumber(_ value: UInt64, language: AppLanguage? = nil) -> String {
        let selectedLanguage = language ?? currentLanguage
        return value.formatted(
            .number
                .locale(selectedLanguage.locale)
                .notation(.compactName)
                .precision(.fractionLength(0...1))
        )
    }
}
