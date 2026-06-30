/// A logical screen identity for the manual `screen_view` event. SwiftUI is a single `UIHostingController`, so
/// Firebase does not auto-collect screen views — each top-level screen emits one explicitly on appear. Raw values are
/// the `screen_name` parameter value (`AnalyticsParameterScreenName`); Firebase surfaces them as `firebase_screen`
/// in BigQuery. Keep these stable.
public enum AnalyticsScreen: String, Sendable {
    case library
    case reader
    case scoreInfo = "score_info"
    case settings
    case recentlyDeleted = "recently_deleted"
    case playlistDetail = "playlist_detail"
    case tagDetail = "tag_detail"
}
