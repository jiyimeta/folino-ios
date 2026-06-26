import Domain
import SwiftUI
import UtilityCore

/// The Settings sheet's privacy section: crash-reporting and usage-analytics opt-outs. Owns the `@AppStorage` flags
/// and forwards changes to the injected reporters so collection state stays in sync with the toggles.
struct PrivacySettingsSection: View {
    let crashReporter: any CrashReporter
    let analytics: any Analytics

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
            }
        } header: {
            Text("settings.privacy.title", bundle: .module)
        }
    }
}
