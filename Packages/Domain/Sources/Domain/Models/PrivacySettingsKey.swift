import Foundation

/// `@AppStorage` / `UserDefaults` keys for privacy-related preferences that persist across sessions.
public enum PrivacySettingsKey {
    /// Bool. Whether Crashlytics crash-data collection is enabled. Opt-out semantics: absent (first launch) is treated
    /// as `true`. Do not rename — the raw string is persisted user state.
    public static let crashReportingEnabled = "privacyCrashReportingEnabled"

    /// Bool. Whether Firebase Analytics collection is enabled. Opt-out semantics: absent (first launch) is treated as
    /// `true`. Do not rename — the raw string is persisted user state.
    public static let analyticsEnabled = "privacyAnalyticsEnabled"
}
