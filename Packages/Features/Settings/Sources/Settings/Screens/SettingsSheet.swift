import Domain
import Observation
import SettingsLogic
import SwiftUI
import UtilityCore
import UtilityUI

@MainActor
public struct SettingsSheet<LicenseContent: View>: View {
    private let licenseContent: () -> LicenseContent
    private let provider: (any MuseScoreGeneralProvider)?
    private let versionHistoryLoader: any VersionHistoryLoader
    private let onVersionHistoryViewed: @MainActor () -> Void
    private let crashReporter: any CrashReporter
    private let analytics: any Analytics
    @Environment(\.dismiss) private var dismiss

    public init(
        provider: (any MuseScoreGeneralProvider)? = nil,
        versionHistoryLoader: any VersionHistoryLoader = DefaultVersionHistoryLoader(),
        onVersionHistoryViewed: @escaping @MainActor () -> Void = {},
        crashReporter: any CrashReporter = NoopCrashReporter(),
        analytics: any Analytics = NoopAnalytics(),
        @ViewBuilder licenseContent: @escaping () -> LicenseContent,
    ) {
        self.provider = provider
        self.versionHistoryLoader = versionHistoryLoader
        self.onVersionHistoryViewed = onVersionHistoryViewed
        self.crashReporter = crashReporter
        self.analytics = analytics
        self.licenseContent = licenseContent
    }

    public var body: some View {
        NavigationStack {
            Form {
                ReaderSettingsSection(provider: provider, analytics: analytics)
                PrivacySettingsSection(crashReporter: crashReporter, analytics: analytics)
                AboutSettingsSection(
                    versionHistoryLoader: versionHistoryLoader,
                    onVersionHistoryViewed: onVersionHistoryViewed,
                    licenseContent: licenseContent,
                )
            }
            .navigationTitle(Text("settings.title", bundle: .module))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { doneToolbar }
        }
        .onAppear { analytics.logScreen(.settings) }
    }

    @ToolbarContentBuilder
    private var doneToolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Button { dismiss() } label: { L10n.Common.done }
        }
    }
}

#Preview("Without provider") {
    SettingsSheet { Text("License placeholder") }
}

#Preview("With provider") {
    SettingsSheet(provider: _StubProvider()) {
        Text("License placeholder")
    }
}

@MainActor
@Observable
private final class _StubProvider: MuseScoreGeneralProvider {
    var isOptedIn = true
    var downloadState: SoundfontDownloadState = .idle

    var isDownloaded: Bool {
        false
    }

    var museScoreGeneralFileURL: URL? {
        nil
    }

    nonisolated var museScoreGeneralFileURLSync: URL? {
        nil
    }

    nonisolated var isCurrentlyWiFi: Bool {
        true
    }

    var currentPreset: SoundfontPreset {
        .lightweight
    }

    func setOptedIn(_: Bool) {}
    func startDownloadIfNeeded() {}
    func startDownloadAllowingCellular() {}
    func cancelDownload() {}
    func deleteDownloaded() {}
}
