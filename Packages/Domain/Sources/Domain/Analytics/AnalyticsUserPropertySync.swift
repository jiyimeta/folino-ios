import UtilityCore

/// Computes and pushes the library user-property snapshot to analytics. Pure mapping; the caller decides when to
/// invoke it (launch, and after import/delete/sort-change for the library half).
///
/// Format is derived from `localFileName` via `ScoreFormat.detect(filename:)` — `ScoreItem` deliberately does not
/// store format as a property. The `museScoreMajorVersion` field is `nil` for non-MuseScore rows and for rows
/// imported before the field was introduced; analytics treats `nil` as v4 (the current default).
public enum AnalyticsUserPropertySync {
    /// Snapshot the library state and push all library-related user properties into `analytics`.
    ///
    /// - Parameters:
    ///   - items: The full set of non-deleted library items.
    ///   - sort: The currently active sort order.
    ///   - analytics: The analytics sink to write into.
    public static func syncLibrary(items: [ScoreItem], sort: ScoreItemSort, into analytics: any Analytics) {
        analytics.setUserProperty(countBucket(items.count), for: .librarySizeBucket)
        analytics.setUserProperty(sort.analyticsValue, for: .currentSortOrder)

        /// Inline helper: bucketed count of items matching a predicate.
        func count(_ predicate: (ScoreItem) -> Bool) -> String {
            countBucket(items.filter(predicate).count)
        }

        /// Format is derived from the filename rather than a stored property.
        func format(of item: ScoreItem) -> ScoreFormat? {
            ScoreFormat.detect(filename: item.localFileName)
        }

        /// For mscz items, return the effective major version (nil → v4 default). Returns nil for non-mscz items.
        func msczMajor(_ item: ScoreItem) -> Int? {
            guard format(of: item) == .mscz else { return nil }
            return item.museScoreMajorVersion ?? 4
        }

        analytics.setUserProperty(count { msczMajor($0) == 2 }, for: .scoreCountMscz2)
        analytics.setUserProperty(count { msczMajor($0) == 3 }, for: .scoreCountMscz3)
        analytics.setUserProperty(count { msczMajor($0) == 4 }, for: .scoreCountMscz4)
        analytics.setUserProperty(
            count { format(of: $0) == .musicXML || format(of: $0) == .mxl },
            for: .scoreCountMusicXML,
        )
        analytics.setUserProperty(count { format(of: $0) == .midi }, for: .scoreCountMidi)
        analytics.setUserProperty(count { format(of: $0) == .pdf }, for: .scoreCountPdf)
    }
}
