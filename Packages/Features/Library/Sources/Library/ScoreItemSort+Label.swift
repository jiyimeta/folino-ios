import Foundation
import LibraryLogic

extension ScoreItemSort {
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
}
