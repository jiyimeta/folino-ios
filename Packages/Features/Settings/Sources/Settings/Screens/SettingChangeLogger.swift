import Domain
import UtilityCore

/// Single funnel for the `setting_changed` analytics event from every Settings control. Centralizing it keeps each
/// control's wire `key` stable in one place and forces all values through one low-cardinality stringification (bool →
/// `"true"`/`"false"`; pickers pass their enum's stable `analyticsValue`/`rawValue`), so no control can leak a raw or
/// high-cardinality value. Every toggle/picker/slider `onChange` in the Settings sections routes through this one type.
@MainActor
struct SettingChangeLogger {
    let analytics: any Analytics

    func log(_ key: SettingKey, _ isOn: Bool) {
        analytics.log(.settingChanged(key: key.rawValue, value: isOn ? "true" : "false"))
    }

    func log(_ key: SettingKey, value: String) {
        analytics.log(.settingChanged(key: key.rawValue, value: value))
    }
}

/// Stable wire identifiers for each Settings control's `setting_changed` event. Independent of the `@AppStorage`
/// `UserDefaults` key strings so a storage-key refactor never shifts analytics, and from the user-facing copy so a
/// wording change never shifts analytics.
enum SettingKey: String {
    case metronome = "metronome_enabled"
    case pictureInPicture = "picture_in_picture_enabled"
    case collapseMultiMeasureRests = "collapse_multi_measure_rests"
    case showInvisibleElements = "show_invisible_elements"
    case keepScreenAwake = "keep_screen_awake"
    case showSeekBar = "show_seek_bar"
    case repeatMode = "repeat_mode"
    case playlistContinuation = "playlist_continuation"
    case a4Reference = "a4_reference_hz"
    case layoutMode = "layout_mode"
    case crashReporting = "crash_reporting_enabled"
    case analytics = "analytics_enabled"
}
