/// The UI surface an action was initiated from. Carried as the `source` parameter on multi-path events
/// (favorite/delete/share/add-to-playlist) so analytics can attribute where each action originates.
public enum AnalyticsSource: String, Sendable {
    case scoreRowMenu = "score_row_menu"
    case bulkEdit = "bulk_edit"
    case readerOverlay = "reader_overlay"
    case scoreInfoSheet = "score_info_sheet"
    case recentlyOpened = "recently_opened"
    case favorites
    case playlist
    case tag
    case searchResult = "search_result"
    case libraryAll = "library_all"
}
