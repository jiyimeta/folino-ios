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

// `SettingKey` (the stable `setting_changed` wire keys) now lives in `Domain` so the Android `AnalyticsBridge`
// resolves the identical catalog ([[feedback_ios_android_parity]]). `import Domain` at the top of this file brings
// it into scope; `SettingChangeLogger` consumes it unchanged.
