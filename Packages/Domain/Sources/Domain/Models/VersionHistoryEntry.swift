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
        let isJa = locale.language.languageCode?.identifier == "ja"
        descriptions = entries.map { isJa ? $0.ja : $0.en }
    }
}
