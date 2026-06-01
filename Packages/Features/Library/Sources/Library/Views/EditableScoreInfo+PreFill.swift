import Domain

extension EditableScoreInfo {
    /// Build the sheet's initial field values. For each optional credit field: a stored value (including an explicit
    /// empty string the user previously saved) wins; only a NULL column falls back to the file's metaTag. Subtitle is
    /// not a metaTag, so it comes straight from the stored value.
    init(item: ScoreItem, fileMetadata: ScoreFileMetadata?) {
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
