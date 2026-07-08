/// Stable wire identifiers for each Settings control's `setting_changed` event. Independent of the `@AppStorage`
/// `UserDefaults` key strings so a storage-key refactor never shifts analytics, and from the user-facing copy so a
/// wording change never shifts analytics.
///
/// Lives in Domain (next to `AnalyticsSource` and the event factories) because it is the shared analytics wire
/// vocabulary: iOS Settings (`SettingChangeLogger`) and the Android `AnalyticsBridge` both resolve their
/// `setting_changed` keys from this one catalog, so the two platforms emit byte-identical keys without duplicating
/// the strings ([[feedback_ios_android_parity]]: lift shared logic, never reimplement a divergent copy).
public enum SettingKey: String, Sendable, CaseIterable {
    case metronome = "metronome_enabled"
    case pictureInPicture = "picture_in_picture_enabled"
    case collapseMultiMeasureRests = "collapse_multi_measure_rests"
    case showInvisibleElements = "show_invisible_elements"
    case keepScreenAwake = "keep_screen_awake"
    case showSeekBar = "show_seek_bar"
    case autoFollow = "auto_follow_enabled"
    case pageTurnButtons = "page_turn_buttons_visible"
    case repeatMode = "repeat_mode"
    case playlistContinuation = "playlist_continuation"
    case a4Reference = "a4_reference_hz"
    case layoutMode = "layout_mode"
    case crashReporting = "crash_reporting_enabled"
    case analytics = "analytics_enabled"

    /// Resolve a `SettingKey` from its Swift case name (e.g. `"metronome"`), the symbolic token the Android bridge
    /// receives across the JNI boundary. The wire `rawValue` is never crossed from Kotlin — the bridge maps the
    /// case-name token here so the wire string is authored only in this Swift catalog.
    public init?(caseToken: String) {
        switch caseToken {
        case "metronome": self = .metronome
        case "pictureInPicture": self = .pictureInPicture
        case "collapseMultiMeasureRests": self = .collapseMultiMeasureRests
        case "showInvisibleElements": self = .showInvisibleElements
        case "keepScreenAwake": self = .keepScreenAwake
        case "showSeekBar": self = .showSeekBar
        case "autoFollow": self = .autoFollow
        case "pageTurnButtons": self = .pageTurnButtons
        case "repeatMode": self = .repeatMode
        case "playlistContinuation": self = .playlistContinuation
        case "a4Reference": self = .a4Reference
        case "layoutMode": self = .layoutMode
        case "crashReporting": self = .crashReporting
        case "analytics": self = .analytics
        default: return nil
        }
    }
}
