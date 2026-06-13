import Domain
import SwiftUI
import UtilityCore

/// The Settings sheet's privacy section: the crash-reporting opt-out. Owns the `@AppStorage` flag and forwards changes
/// to the injected `CrashReporter` so the collection state stays in sync with the toggle.
struct PrivacySettingsSection: View {
    let crashReporter: any CrashReporter

    @AppStorage(PrivacySettingsKey.crashReportingEnabled)
    private var isCrashReportingEnabled = true

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
        } header: {
            Text("settings.privacy.title", bundle: .module)
        }
    }
}
