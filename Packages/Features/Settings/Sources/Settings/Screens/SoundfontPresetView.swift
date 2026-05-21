import Domain
import SwiftUI
import UtilityUI

/// Embeddable Settings section for the high-quality soundfont download. Designed to slot directly into the parent
/// `Form` — no `NavigationStack` of its own. The accessory in the title row morphs based on `downloadState`:
///
/// - idle / downloaded / failed → standard `Toggle`
/// - downloading → circular determinate progress + stop button (cancels the in-flight download)
///
/// Toggle interactions confirmation-gate via alerts:
///
/// - turning **on** when Wi-Fi is unavailable → "no Wi-Fi" alert offers "download now over cellular" vs "wait for
///   Wi-Fi" (or cancel, which reverts the toggle).
/// - turning **off** when the file is already downloaded → "delete cache" confirmation. Cancelling reverts.
@MainActor
struct SoundfontPresetSection: View {
    let provider: any MuseScoreGeneralProvider

    @State private var isOptedIn = true
    @State private var downloadState: SoundfontDownloadState = .idle
    @State private var noWiFiAlertPresented = false
    @State private var deleteCacheAlertPresented = false

    var body: some View {
        Section {
            row
            if isOptedIn, case .failed = downloadState {
                Button {
                    Task { await provider.startDownloadIfNeeded() }
                } label: {
                    Label {
                        Text("settings.soundfont.retry", bundle: .module)
                    } icon: { Image(systemName: "arrow.clockwise") }
                }
            }
        } header: {
            Text("settings.soundfont.title", bundle: .module)
        }
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
                Task { await applyOptedIn(true, cellular: true) }
            } label: { Text("settings.soundfont.wifi.alert.now", bundle: .module) }
            Button {
                Task { await applyOptedIn(true, cellular: false) }
            } label: { Text("settings.soundfont.wifi.alert.wait", bundle: .module) }
            Button(role: .cancel) {
                isOptedIn = false
            } label: { L10n.Common.cancel }
        } message: {
            Text("settings.soundfont.wifi.alert.message", bundle: .module)
        }
        .alert(
            Text("settings.soundfont.delete.alert.title", bundle: .module),
            isPresented: $deleteCacheAlertPresented,
        ) {
            Button(role: .destructive) {
                Task { await applyOptedIn(false, cellular: false) }
            } label: { Text("settings.soundfont.delete.alert.confirm", bundle: .module) }
            Button(role: .cancel) {
                isOptedIn = true
            } label: { L10n.Common.cancel }
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
            Button {
                Task { await provider.cancelDownload() }
            } label: {
                ZStack {
                    Circle()
                        .stroke(.secondary.opacity(0.25), lineWidth: 3)
                    Circle()
                        .trim(from: 0, to: max(0.02, progress))
                        .stroke(
                            Color.accentColor,
                            style: StrokeStyle(lineWidth: 3, lineCap: .round),
                        )
                        .rotationEffect(.degrees(-90))
                    Image(systemName: "stop.fill")
                        .imageScale(.small)
                        .foregroundStyle(.tint)
                }
                .frame(width: 28, height: 28)
                .contentShape(Circle())
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(Text("settings.soundfont.stop.label", bundle: .module))
        } else {
            Toggle("", isOn: $isOptedIn)
                .labelsHidden()
                .onChange(of: isOptedIn) { _, newValue in handleToggleChange(newValue) }
        }
    }

    @ViewBuilder
    private var stateSubtitle: some View {
        switch downloadState {
        case .idle:
            if isOptedIn {
                Text("settings.soundfont.state.waitingForWiFi", bundle: .module)
            } else {
                Text("settings.soundfont.state.optedOut", bundle: .module)
            }
        case let .downloading(progress):
            Text(verbatim: String(
                format: String(localized: "settings.soundfont.state.downloading", bundle: .module),
                Int(progress * 100),
            ))
        case .downloaded:
            Text("settings.soundfont.state.downloaded", bundle: .module)
        case let .failed(reason):
            Text(verbatim: String(localized: "settings.soundfont.state.failed", bundle: .module) + " (\(reason))")
                .foregroundStyle(.red)
        }
    }

    private func handleToggleChange(_ newValue: Bool) {
        if newValue {
            if provider.isCurrentlyWiFi {
                Task { await applyOptedIn(true, cellular: false) }
            } else {
                noWiFiAlertPresented = true
            }
        } else {
            if case .downloaded = downloadState {
                deleteCacheAlertPresented = true
            } else {
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
