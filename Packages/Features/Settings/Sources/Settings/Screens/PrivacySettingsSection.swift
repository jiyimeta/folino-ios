import Domain
import SwiftUI
import UtilityCore

/// The Settings sheet's privacy section: crash-reporting and usage-analytics opt-outs. Owns the `@AppStorage` flags
/// and forwards changes to the injected reporters so collection state stays in sync with the toggles.
struct PrivacySettingsSection: View {
    let crashReporter: any CrashReporter
    let analytics: any Analytics

    private var changeLog: SettingChangeLogger {
        SettingChangeLogger(analytics: analytics)
    }

    @AppStorage(PrivacySettingsKey.crashReportingEnabled)
    private var isCrashReportingEnabled = true

    @AppStorage(PrivacySettingsKey.analyticsEnabled)
    private var isAnalyticsEnabled = true

    var body: some View {
        Section {
            Toggle(isOn: $isCrashReportingEnabled) {
                Label {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("settings.privacy.crashReporting.title", bundle: .module)
                        Text("settings.privacy.crashReporting.footer", bundle: .module)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "ladybug")
                }
            }
            .onChange(of: isCrashReportingEnabled) { _, newValue in
                crashReporter.setCollectionEnabled(newValue)
                changeLog.log(.crashReporting, newValue)
            }
            Toggle(isOn: $isAnalyticsEnabled) {
                Label {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("settings.privacy.analytics.title", bundle: .module)
                        Text("settings.privacy.analytics.footer", bundle: .module)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "chart.bar.xaxis")
                }
            }
            .onChange(of: isAnalyticsEnabled) { _, newValue in
                analytics.setCollectionEnabled(newValue)
                // Log AFTER toggling collection: enabling records the change, while disabling is silently dropped by
                // the now-off analytics sink — opting out never emits a parting event, and there is no half-state.
                changeLog.log(.analytics, newValue)
            }
        } header: {
            Text("settings.privacy.title", bundle: .module)
        }
    }
}
