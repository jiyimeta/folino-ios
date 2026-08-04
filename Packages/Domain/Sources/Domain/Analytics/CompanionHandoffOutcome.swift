/// How far a companion-app hand-off actually got. Logged instead of a bare tap count because the gap between
/// "wanted this" and "could have this" is the number that says whether the companion integration paid off.
public enum CompanionHandoffOutcome: String, Sendable {
    case deepLink = "deep_link"
    case shareFallback = "share_fallback"
    case appStore = "app_store"
    case failed
}
