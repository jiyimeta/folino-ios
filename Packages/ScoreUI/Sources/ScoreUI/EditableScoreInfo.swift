import Domain

/// Mutable form payload for the edit-info sheet. Empty strings are meaningful — saving an empty field clears it
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

    /// Build the sheet's initial field values. For each optional credit field: a stored value (including an explicit
    /// empty string the user previously saved) wins; only a NULL column falls back to the file's metaTag. Subtitle is
    /// not a metaTag, so it comes straight from the stored value.
    public init(item: ScoreItem, fileMetadata: ScoreFileMetadata?) {
        self.init(
            title: item.title,
            subtitle: item.subtitle ?? "",
            composer: item.composer ?? fileMetadata?.composer ?? "",
            arranger: item.arranger ?? fileMetadata?.arranger ?? "",
            lyricist: item.lyricist ?? fileMetadata?.lyricist ?? "",
            copyright: item.copyright ?? fileMetadata?.copyright ?? "",
        )
    }
}
