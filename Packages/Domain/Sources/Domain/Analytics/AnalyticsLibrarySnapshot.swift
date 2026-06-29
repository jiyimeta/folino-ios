import UtilityCore

/// Pure mapping from library state to the `library_snapshot` event. Format is derived from `localFileName` via
/// `ScoreFormat.detect(filename:)` — `ScoreItem` deliberately does not store format as a property.
/// `museScoreMajorVersion` is `nil` for non-MuseScore rows and for rows imported before the field was introduced;
/// analytics treats `nil` as v4 (the current default). Counts are raw — bucket at analysis time.
///
/// Lifted into Domain so iOS and a future Android path share one implementation without duplicating predicate logic.
public enum AnalyticsLibrarySnapshot {
    /// Build the `library_snapshot` event from the current library state.
    ///
    /// - Parameters:
    ///   - items: The full set of non-deleted library items.
    ///   - playlistCount: Total number of playlists (supplied by the caller; not derivable from `ScoreItem`).
    ///   - tagCount: Total number of tags (supplied by the caller; not derivable from `ScoreItem`).
    public static func event(items: [ScoreItem], playlistCount: Int, tagCount: Int) -> AnalyticsEvent {
        func format(of item: ScoreItem) -> ScoreFormat? {
            ScoreFormat.detect(filename: item.localFileName)
        }

        /// For mscz items, return the effective major version (nil → v4 default). Returns nil for non-mscz items.
        func msczMajor(_ item: ScoreItem) -> Int? {
            guard format(of: item) == .mscz else { return nil }
            return item.museScoreMajorVersion ?? 4
        }

        func count(_ predicate: (ScoreItem) -> Bool) -> Int {
            items.filter(predicate).count
        }

        return .librarySnapshot(
            total: items.count,
            mscz2: count { msczMajor($0) == 2 },
            mscz3: count { msczMajor($0) == 3 },
            mscz4: count { msczMajor($0) == 4 },
            musicXML: count { format(of: $0) == .musicXML || format(of: $0) == .mxl },
            midi: count { format(of: $0) == .midi },
            pdf: count { format(of: $0) == .pdf },
            playlistCount: playlistCount,
            tagCount: tagCount,
            favoriteCount: count { $0.isFavorite },
        )
    }
}
