import Foundation

/// Mutable form payload for the edit-info screen. Empty strings are meaningful — saving an empty field clears it
/// (persisted as `""`, which suppresses future file pre-fill).
public struct EditableScoreInfo: Equatable {
    public var title: String
    public var subtitle: String
    public var composer: String
    public var arranger: String
    public var lyricist: String
    public var copyright: String

    public init(
        title: String,
        subtitle: String,
        composer: String,
        arranger: String,
        lyricist: String,
        copyright: String,
    ) {
        self.title = title
        self.subtitle = subtitle
        self.composer = composer
        self.arranger = arranger
        self.lyricist = lyricist
        self.copyright = copyright
    }

    /// Build the screen's initial field values from a stored `ScoreItem` plus optional on-disk metaTags.
    public init(item: ScoreItem, fileMetadata: ScoreFileMetadata?) {
        self = EditableScoreInfo.prefilled(
            title: item.title,
            subtitle: item.subtitle,
            composer: item.composer,
            arranger: item.arranger,
            lyricist: item.lyricist,
            copyright: item.copyright,
            fileMetadata: fileMetadata,
        )
    }

    /// The single shared pre-fill rule (iOS + Android call this). For each optional credit field a stored value
    /// (including an explicit empty string the user previously saved) wins; only `nil` falls back to the file's
    /// metaTag. Subtitle is not a metaTag, so it never falls back.
    public static func prefilled(
        title: String,
        subtitle: String?,
        composer: String?,
        arranger: String?,
        lyricist: String?,
        copyright: String?,
        fileMetadata: ScoreFileMetadata?,
    ) -> EditableScoreInfo {
        EditableScoreInfo(
            title: title,
            subtitle: subtitle ?? "",
            composer: composer ?? fileMetadata?.composer ?? "",
            arranger: arranger ?? fileMetadata?.arranger ?? "",
            lyricist: lyricist ?? fileMetadata?.lyricist ?? "",
            copyright: copyright ?? fileMetadata?.copyright ?? "",
        )
    }

    /// Trim every field on whitespace/newlines. Returns `nil` when the trimmed title is empty (title is required);
    /// other fields keep their trimmed value, with empties preserved as `""` (an explicit "cleared" value).
    public func normalized() -> EditableScoreInfo? {
        func trim(_ s: String) -> String {
            s.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let t = trim(title)
        guard !t.isEmpty else { return nil }
        return EditableScoreInfo(
            title: t,
            subtitle: trim(subtitle),
            composer: trim(composer),
            arranger: trim(arranger),
            lyricist: trim(lyricist),
            copyright: trim(copyright),
        )
    }
}
