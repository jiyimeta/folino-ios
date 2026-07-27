import Foundation

/// The four fields a score list can be ordered by. Conformed by `ScoreItem` (the iOS library model) and by the
/// Android JNI bridge's persistence projection, so both platforms order their lists through the *same* comparators
/// in `ScoreItemSort` instead of each re-deriving "newest first" or "composer, nils last".
public protocol ScoreSortFields {
    var sortTitle: String { get }
    var sortComposer: String? { get }
    var sortAddedAt: Date { get }
    /// `nil` for a score that has never been opened — those sort last under `.lastOpenedDesc`.
    var sortLastOpenedAt: Date? { get }
}

extension ScoreItem: ScoreSortFields {
    public var sortTitle: String {
        title
    }

    public var sortComposer: String? {
        composer
    }

    public var sortAddedAt: Date {
        addedAt
    }

    public var sortLastOpenedAt: Date? {
        lastOpenedAt
    }
}

/// Sort options for any score list view (All / Tag-filtered / Playlist).
public enum ScoreItemSort: String, CaseIterable, Identifiable, Sendable {
    case dateAddedDesc
    case titleAsc
    case composerAsc
    case lastOpenedDesc

    public var id: String {
        rawValue
    }

    /// Parses a persisted raw value, falling back to the shipping default (`.dateAddedDesc`) for an absent or
    /// unrecognized string — a value written by a future build must never leave a list unsorted.
    public static func parse(_ raw: String?) -> ScoreItemSort {
        raw.flatMap(ScoreItemSort.init(rawValue:)) ?? .dateAddedDesc
    }

    public func apply<T: ScoreSortFields>(to items: [T]) -> [T] {
        switch self {
        case .dateAddedDesc:
            items.sorted(by: Self.dateAddedDescComparator)
        case .titleAsc:
            items.sorted(by: Self.titleAscComparator)
        case .composerAsc:
            items.sorted(by: Self.composerAscComparator)
        case .lastOpenedDesc:
            items.sorted(by: Self.lastOpenedDescComparator)
        }
    }

    private static func dateAddedDescComparator(_ lhs: some ScoreSortFields, _ rhs: some ScoreSortFields) -> Bool {
        lhs.sortAddedAt > rhs.sortAddedAt
    }

    private static func titleAscComparator(_ lhs: some ScoreSortFields, _ rhs: some ScoreSortFields) -> Bool {
        lhs.sortTitle.localizedStandardCompare(rhs.sortTitle) == .orderedAscending
    }

    private static func composerAscComparator(_ lhs: some ScoreSortFields, _ rhs: some ScoreSortFields) -> Bool {
        switch (lhs.sortComposer, rhs.sortComposer) {
        case let (left?, right?): left.localizedStandardCompare(right) == .orderedAscending
        case (_?, nil): true
        case (nil, _?): false
        case (nil, nil): false
        }
    }

    private static func lastOpenedDescComparator(_ lhs: some ScoreSortFields, _ rhs: some ScoreSortFields) -> Bool {
        switch (lhs.sortLastOpenedAt, rhs.sortLastOpenedAt) {
        case let (left?, right?): left > right
        case (_?, nil): true
        case (nil, _?): false
        case (nil, nil): false
        }
    }
}

/// `UserDefaults` keys for Library settings that persist across launches. Co-located with `ScoreItemSort` so the raw
/// string is not duplicated as a literal across packages (mirrors `ReaderGlobalSettingsKey`).
public enum LibrarySettingsKey {
    /// `ScoreItemSort.rawValue` (String). The global sort order for the All / Favorites / Tag score lists, applied and
    /// persisted across launches. Defaults to `ScoreItemSort.dateAddedDesc` when absent. Playlists keep their own
    /// manual order and neither read nor write this key.
    public static let sortOrder = "librarySortOrder"
}
