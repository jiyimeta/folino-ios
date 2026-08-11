import Foundation

public struct VersionHistoryEntry: Equatable, Identifiable, Sendable, Decodable {
    public let version: AppVersion
    public let descriptions: [String]
    public var id: AppVersion {
        version
    }

    public init(version: AppVersion, descriptions: [String]) {
        self.version = version
        self.descriptions = descriptions
    }

    /// Inject a `Locale` into `Decoder.userInfo` under this key to override the default `Locale.current` lookup.
    /// Android must set it — the JNI library's `Locale.current` reflects the Swift runtime's environment, not the
    /// device language, so the host passes Android's own language tag down. iOS can leave `userInfo` empty.
    public static let localeUserInfoKey: CodingUserInfoKey = // swiftlint:disable:next force_unwrapping
        .init(rawValue: "VersionHistoryEntry.locale")!

    private enum CodingKeys: String, CodingKey {
        case version
        case descriptions
    }

    private struct LocalizedDescription: Decodable {
        let en: String
        let ja: String
        // Newer locales are optional so a future entry that forgets a translation falls back to en instead of being
        // silently dropped by the loader's `try?` decode.
        let zhHans: String?
        let zhHant: String?
        let ko: String?

        private enum CodingKeys: String, CodingKey {
            case en
            case ja
            case zhHans = "zh-Hans"
            case zhHant = "zh-Hant"
            case ko
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let versionString = try container.decode(String.self, forKey: .version)
        guard let parsed = AppVersion(versionString) else {
            throw DecodingError.dataCorruptedError(
                forKey: .version,
                in: container,
                debugDescription: "Malformed version string: \(versionString)",
            )
        }
        version = parsed

        let entries = try container.decode([LocalizedDescription].self, forKey: .descriptions)
        let locale = decoder.userInfo[Self.localeUserInfoKey] as? Locale ?? .current
        let lang = locale.language.languageCode?.identifier
        let script = locale.language.script?.identifier ?? Self.impliedScript(of: locale, language: lang)
        descriptions = entries.map { entry in
            switch (lang, script) {
            case ("ja", _): entry.ja
            case ("ko", _): entry.ko ?? entry.en
            case ("zh", "Hans"): entry.zhHans ?? entry.en
            case ("zh", "Hant"): entry.zhHant ?? entry.en
            default: entry.en
            }
        }
    }

    /// The script a Chinese locale means when it doesn't spell one out. A tag like `zh-CN` carries the script only
    /// through CLDR's likely-subtags, which `Locale` resolves on Apple platforms but not necessarily elsewhere —
    /// Android hands us whatever `java.util.Locale.getDefault().toLanguageTag()` produced. Deriving it from the
    /// region here keeps both platforms on one rule instead of leaving Simplified/Traditional users on English.
    private static func impliedScript(of locale: Locale, language: String?) -> String? {
        guard language == "zh" else {
            return nil
        }
        return switch locale.region?.identifier {
        case "TW", "HK", "MO": "Hant"
        default: "Hans"
        }
    }
}
