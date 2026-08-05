/// How far a companion-app hand-off actually got. Logged instead of a bare tap count because the gap between
/// "wanted this" and "could have this" is the number that says whether the companion integration paid off.
public enum CompanionHandoffOutcome: String, Sendable {
    case deepLink = "deep_link"
    case shareFallback = "share_fallback"
    case appStore = "app_store"
    case failed
}

/// Which companion app a hand-off was aimed at. A typed case rather than a bare string at each call site: the raw
/// value is the analytics dimension the whole feature is read by, and a typo would silently mis-bucket one outcome.
public enum CompanionTarget: String, Sendable {
    case vocalTuner = "vocaltuner"
}
