import Domain
import Foundation

/// Sort options for any score list view (All / Tag-filtered / Playlist).
enum ScoreItemSort: String, CaseIterable, Identifiable {
    case dateAddedDesc
    case titleAsc
    case composerAsc
    case lastOpenedDesc

    var id: String {
        rawValue
    }

    var labelKey: LocalizedStringResource {
        switch self {
        case .dateAddedDesc:
            LocalizedStringResource("library.sort.byDateAdded", bundle: .atURL(Bundle.module.bundleURL))
        case .titleAsc:
            LocalizedStringResource("library.sort.byTitle", bundle: .atURL(Bundle.module.bundleURL))
        case .composerAsc:
            LocalizedStringResource("library.sort.byComposer", bundle: .atURL(Bundle.module.bundleURL))
        case .lastOpenedDesc:
            LocalizedStringResource("library.sort.byLastOpened", bundle: .atURL(Bundle.module.bundleURL))
        }
    }

    func apply(to items: [ScoreItem]) -> [ScoreItem] {
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

    private static func dateAddedDescComparator(_ lhs: ScoreItem, _ rhs: ScoreItem) -> Bool {
        lhs.addedAt > rhs.addedAt
    }

    private static func titleAscComparator(_ lhs: ScoreItem, _ rhs: ScoreItem) -> Bool {
        lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
    }

    private static func composerAscComparator(_ lhs: ScoreItem, _ rhs: ScoreItem) -> Bool {
        switch (lhs.composer, rhs.composer) {
        case let (left?, right?): left.localizedStandardCompare(right) == .orderedAscending
        case (_?, nil): true
        case (nil, _?): false
        case (nil, nil): false
        }
    }

    private static func lastOpenedDescComparator(_ lhs: ScoreItem, _ rhs: ScoreItem) -> Bool {
        switch (lhs.lastOpenedAt, rhs.lastOpenedAt) {
        case let (left?, right?): left > right
        case (_?, nil): true
        case (nil, _?): false
        case (nil, nil): false
        }
    }
}
