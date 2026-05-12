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

    /// Inject a `Locale` into `Decoder.userInfo` under this key to override
    /// the default `Locale.current` lookup. Tests use this; production code
    /// can leave `userInfo` empty.
    static let localeUserInfoKey: CodingUserInfoKey = // swiftlint:disable:next force_unwrapping
        .init(rawValue: "VersionHistoryEntry.locale")!

    private enum CodingKeys: String, CodingKey {
        case version
        case descriptions
    }

    private struct LocalizedDescription: Decodable {
        let en: String
        let ja: String
        // Newer locales are optional so a future entry that forgets a translation
        // falls back to en instead of being silently dropped by the loader's
        // `try?` decode.
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
        let script = locale.language.script?.identifier
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
}
