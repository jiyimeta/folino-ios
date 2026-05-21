import Domain
import SwiftUI
import UtilityUI

/// Embeddable Settings row for the high-quality soundfont download. Designed to drop into an existing `Section` (the
/// Reader section in SettingsSheet) — no `Section`/`NavigationStack` of its own. The accessory morphs based on
/// `downloadState`:
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
@MainActor
struct SoundfontPresetRow: View {
    let provider: any MuseScoreGeneralProvider

    @State private var isOptedIn = true
    @State private var downloadState: SoundfontDownloadState = .idle
    @State private var noWiFiAlertPresented = false
    @State private var deleteCacheAlertPresented = false

    var body: some View {
        row
            .task {
                isOptedIn = await provider.isOptedIn
                for await state in provider.downloadStateStream() {
                    downloadState = state
                }
            }
            .alert(
                Text("settings.soundfont.wifi.alert.title", bundle: .module),
                isPresented: $noWiFiAlertPresented,
            ) {
                Button {
                    isOptedIn = true
                    Task { await applyOptedIn(true, cellular: true) }
                } label: { Text("settings.soundfont.wifi.alert.now", bundle: .module) }
                Button {
                    isOptedIn = true
                    Task { await applyOptedIn(true, cellular: false) }
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
                    isOptedIn = false
                    Task { await applyOptedIn(false, cellular: false) }
                } label: { Text("settings.soundfont.delete.alert.confirm", bundle: .module) }
                Button(role: .cancel) {} label: { L10n.Common.cancel }
            } message: {
                Text("settings.soundfont.delete.alert.message", bundle: .module)
            }
    }

    private var row: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("settings.soundfont.highQuality.title", bundle: .module)
                stateSubtitle
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            accessory
        }
    }

    @ViewBuilder
    private var accessory: some View {
        if case let .downloading(progress) = downloadState {
            stopSpinner(determinate: progress) {
                Task { await provider.cancelDownload() }
            }
        } else if isOptedIn, case .idle = downloadState {
            // Opted in but waiting for the network policy / next Wi-Fi window. Show an indeterminate spinner with the
            // same visual weight as the downloading state; tapping the stop button opts out (matches the user's
            // expectation that the spinner means "in progress" and the stop button means "stop trying").
            stopSpinner(determinate: nil) {
                isOptedIn = false
                Task { await applyOptedIn(false, cellular: false) }
            }
        } else {
            Toggle("", isOn: toggleBinding)
                .labelsHidden()
        }
    }

    /// Displayed toggle state. Defers to `isOptedIn` except in `.failed`, where the toggle reads as off so the user can
    /// re-flip it on to retry — `setOptedIn(true)` re-runs `startDownloadIfNeeded` whether the underlying flag was
    /// already true or not, making the on-tap a natural retry gesture.
    private var toggleBinding: Binding<Bool> {
        Binding(
            get: {
                if case .failed = downloadState { return false }
                return isOptedIn
            },
            set: { newValue in handleToggleChange(newValue) },
        )
    }

    private func stopSpinner(
        determinate progress: Double?,
        onTap: @escaping () -> Void,
    ) -> some View {
        Button(action: onTap) {
            ZStack {
                Circle()
                    .stroke(.secondary.opacity(0.25), lineWidth: 3)
                if let progress {
                    Circle()
                        .trim(from: 0, to: max(0.02, progress))
                        .stroke(
                            Color.accentColor,
                            style: StrokeStyle(lineWidth: 3, lineCap: .round),
                        )
                        .rotationEffect(.degrees(-90))
                } else {
                    IndeterminateArc()
                }
                Image(systemName: "stop.fill")
                    .imageScale(.small)
                    .foregroundStyle(.tint)
            }
            .frame(width: 28, height: 28)
            .contentShape(Circle())
        }
        .buttonStyle(.borderless)
        .accessibilityLabel(Text("settings.soundfont.stop.label", bundle: .module))
    }

    @ViewBuilder
    private var stateSubtitle: some View {
        switch downloadState {
        case .idle:
            if isOptedIn {
                // The localized value embeds a markdown link (folino-action://download-now) styled as a tinted inline
                // link. The `openURL` handler below intercepts that custom URL and routes it to the same code path the
                // "Download Now" alert button uses — bypassing the Wi-Fi gate.
                Text("settings.soundfont.state.waitingForWiFi", bundle: .module)
                    .environment(\.openURL, OpenURLAction { url in
                        if url.scheme == "folino-action", url.host == "download-now" {
                            Task { await provider.startDownloadAllowingCellular() }
                            return .handled
                        }
                        return .systemAction
                    })
            }
        case .downloading, .downloaded:
            EmptyView()
        case let .failed(reason):
            Text(verbatim: String(localized: "settings.soundfont.state.failed", bundle: .module) + " (\(reason))")
                .foregroundStyle(.red)
        }
    }

    private func handleToggleChange(_ newValue: Bool) {
        if newValue {
            if provider.isCurrentlyWiFi {
                isOptedIn = true
                Task { await applyOptedIn(true, cellular: false) }
            } else {
                noWiFiAlertPresented = true
            }
        } else {
            if case .downloaded = downloadState {
                deleteCacheAlertPresented = true
            } else {
                isOptedIn = false
                Task { await applyOptedIn(false, cellular: false) }
            }
        }
    }

    private func applyOptedIn(_ value: Bool, cellular: Bool) async {
        await provider.setOptedIn(value)
        if value, cellular {
            await provider.startDownloadAllowingCellular()
        }
    }
}

/// Continuously-spinning arc, matching the visual weight of the determinate progress arc. Lives in its own struct so
/// `@State` can drive the `withAnimation` repeat without leaking the animation flag into the parent view's state.
private struct IndeterminateArc: View {
    @State private var angle: Double = 0

    var body: some View {
        Circle()
            .trim(from: 0, to: 0.25)
            .stroke(
                Color.accentColor,
                style: StrokeStyle(lineWidth: 3, lineCap: .round),
            )
            .rotationEffect(.degrees(angle))
            .onAppear {
                withAnimation(.linear(duration: 1.0).repeatForever(autoreverses: false)) {
                    angle = 360
                }
            }
    }
}

#if DEBUG
private struct PreviewStubProvider: MuseScoreGeneralProvider {
    let optedIn: Bool
    let state: SoundfontDownloadState
    let downloaded: Bool
    let wifi: Bool

    var isOptedIn: Bool {
        optedIn
    }

    var isDownloaded: Bool {
        downloaded
    }

    var museScoreGeneralFileURL: URL? {
        downloaded ? URL(filePath: "/tmp/MuseScore_General.sf2") : nil
    }

    var museScoreGeneralFileURLSync: URL? {
        museScoreGeneralFileURL
    }

    var isCurrentlyWiFi: Bool {
        wifi
    }

    var currentPreset: SoundfontPreset {
        downloaded ? .highQuality : .lightweight
    }

    func setOptedIn(_: Bool) {}
    func downloadStateStream() -> AsyncStream<SoundfontDownloadState> {
        AsyncStream { continuation in
            continuation.yield(state)
        }
    }

    func startDownloadIfNeeded() {}
    func startDownloadAllowingCellular() {}
    func cancelDownload() {}
    func deleteDownloaded() {}
}

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
