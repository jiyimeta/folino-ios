import Domain
import Observation
import SwiftUI
import UtilityUI

/// Embeddable Settings row for the high-quality soundfont download. Designed to drop into an existing `Section` (the
/// Reader section in SettingsSheet) — no `Section`/`NavigationStack` of its own. The accessory morphs based on
/// `provider.downloadState`:
///
/// - downloading → determinate circular progress + stop button (cancels the in-flight download)
/// - opted-in + idle → indeterminate spinner + stop button (opts out)
/// - everything else → standard `Toggle`
///
/// Toggle interactions confirmation-gate via alerts:
///
/// - turning **on** when Wi-Fi is unavailable → "no Wi-Fi" alert offers "download now over cellular" vs "wait for
///   Wi-Fi" (or cancel, which reverts the toggle).
/// - turning **off** when the file is already downloaded → "delete cache" confirmation. Cancelling reverts.
///
/// State comes directly off the `@Observable` provider — no `@State` mirror layer.
@MainActor
struct SoundfontPresetRow: View {
    let provider: any MuseScoreGeneralProvider

    @State private var noWiFiAlertPresented = false
    @State private var deleteCacheAlertPresented = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            SoundfontPresetRowContent(
                downloadState: provider.downloadState,
                isOptedIn: provider.isOptedIn,
                toggleBinding: toggleBinding,
                onDownloadNow: { provider.startDownloadAllowingCellular() },
                onCancelDownload: { provider.cancelDownload() },
                onStopOptOut: { provider.setOptedIn(false) },
            )
            .alert(
                Text("settings.soundfont.wifi.alert.title", bundle: .module),
                isPresented: $noWiFiAlertPresented,
            ) {
                Button {
                    provider.setOptedIn(true)
                    provider.startDownloadAllowingCellular()
                } label: { Text("settings.soundfont.wifi.alert.now", bundle: .module) }
                Button {
                    provider.setOptedIn(true)
                } label: { Text("settings.soundfont.wifi.alert.wait", bundle: .module) }
                Button(role: .cancel) {} label: { L10n.Common.cancel }
            } message: {
                Text("settings.soundfont.wifi.alert.message", bundle: .module)
            }
            .alert(
                Text("settings.soundfont.delete.alert.title", bundle: .module),
                isPresented: $deleteCacheAlertPresented,
            ) {
                Button(role: .destructive) {
                    provider.setOptedIn(false)
                } label: { Text("settings.soundfont.delete.alert.confirm", bundle: .module) }
                Button(role: .cancel) {} label: { L10n.Common.cancel }
            } message: {
                Text("settings.soundfont.delete.alert.message", bundle: .module)
            }

            siblingNote
        }
    }

    @ViewBuilder
    private var siblingNote: some View {
        if let siblingName = provider.soundfontKeptBySiblingDisplayName {
            // Opted out, but a sibling keeps the shared file on device.
            Text(verbatim: String(
                format: String(localized: "settings.soundfont.keptBySibling", bundle: .module),
                siblingName, siblingName,
            ))
            .font(.footnote)
            .foregroundStyle(.secondary)
        } else if provider.isOptedIn, provider.museScoreGeneralFileURLSync != nil,
                  let siblingName = provider.siblingInstalledDisplayName
        {
            // Opted in + file present + sibling installed → one shared file across both apps (saves space).
            Text(verbatim: String(
                format: String(localized: "settings.soundfont.sharingWith", bundle: .module),
                siblingName,
            ))
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
    }

    /// Displayed toggle state. Defers to `provider.isOptedIn` except in `.failed`, where the toggle reads as off so the
    /// user can re-flip it on to retry — `setOptedIn(true)` re-runs `startDownloadIfNeeded` whether the underlying flag
    /// was already true or not, making the on-tap a natural retry gesture.
    private var toggleBinding: Binding<Bool> {
        Binding(
            get: {
                if case .failed = provider.downloadState { return false }
                return provider.isOptedIn
            },
            set: { newValue in handleToggleChange(newValue) },
        )
    }

    private func handleToggleChange(_ newValue: Bool) {
        if newValue {
            if provider.isCurrentlyWiFi {
                provider.setOptedIn(true)
            } else {
                noWiFiAlertPresented = true
            }
        } else {
            if case .downloaded = provider.downloadState, provider.siblingInUseDisplayName == nil {
                // File on device and no sibling is using it → opting out reclaims it. Confirm the deletion.
                deleteCacheAlertPresented = true
            } else {
                // No file to delete, or an installed sibling keeps it on device → opt out without deleting.
                provider.setOptedIn(false)
            }
        }
    }
}

#if DEBUG
@MainActor
@Observable
private final class PreviewStubProvider: MuseScoreGeneralProvider {
    var isOptedIn: Bool
    var downloadState: SoundfontDownloadState
    @ObservationIgnored let downloaded: Bool
    @ObservationIgnored nonisolated let wifi: Bool

    init(optedIn: Bool, state: SoundfontDownloadState, downloaded: Bool, wifi: Bool) {
        isOptedIn = optedIn
        downloadState = state
        self.downloaded = downloaded
        self.wifi = wifi
    }

    var isDownloaded: Bool {
        downloaded
    }

    var museScoreGeneralFileURL: URL? {
        downloaded ? URL(filePath: "/tmp/MuseScore_General.sf2") : nil
    }

    nonisolated var museScoreGeneralFileURLSync: URL? {
        nil
    }

    nonisolated var isCurrentlyWiFi: Bool {
        wifi
    }

    var currentPreset: SoundfontPreset {
        downloaded ? .highQuality : .lightweight
    }

    func setOptedIn(_: Bool) {}
    func startDownloadIfNeeded() {}
    func startDownloadAllowingCellular() {}
    func cancelDownload() {}
    func deleteDownloaded() {}
}

@MainActor
private func previewRow(
    optedIn: Bool,
    state: SoundfontDownloadState,
    downloaded: Bool = false,
    wifi: Bool = true,
) -> some View {
    Section {
        SoundfontPresetRow(
            provider: PreviewStubProvider(
                optedIn: optedIn, state: state, downloaded: downloaded, wifi: wifi,
            ),
        )
    }
}

#Preview {
    Form {
        previewRow(optedIn: false, state: .idle)
        previewRow(optedIn: false, state: .idle, wifi: false)
        previewRow(optedIn: true, state: .idle, wifi: false)
        previewRow(optedIn: true, state: .downloading(progress: 0.32))
        previewRow(optedIn: true, state: .downloaded, downloaded: true)
        previewRow(optedIn: true, state: .failed(reason: "HTTP 404"))
    }
    .environment(\.locale, Locale(identifier: "ja"))
}
#endif
