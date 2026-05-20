import Domain
import SwiftUI
import UtilityUI

@MainActor
struct SoundfontPresetView: View {
    let provider: any MuseScoreGeneralProvider

    @State private var isOptedIn = true
    @State private var downloadState: SoundfontDownloadState = .idle
    @State private var canUseCellular = false

    var body: some View {
        Form {
            Section {
                Toggle(isOn: $isOptedIn) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("settings.soundfont.highQuality.title", bundle: .module)
                        Text("settings.soundfont.highQuality.subtitle", bundle: .module)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                .onChange(of: isOptedIn) { _, newValue in
                    Task { await provider.setOptedIn(newValue) }
                }
            } footer: {
                stateFooter
            }

            if isOptedIn, case .failed = downloadState {
                Section {
                    Button {
                        Task { await provider.startDownloadIfNeeded() }
                    } label: {
                        Label {
                            Text("settings.soundfont.retry", bundle: .module)
                        } icon: { Image(systemName: "arrow.clockwise") }
                    }
                }
            }

            if isOptedIn, !isCurrentlyDownloaded, canUseCellular {
                Section {
                    Button {
                        Task { await provider.startDownloadAllowingCellular() }
                    } label: {
                        Label {
                            Text("settings.soundfont.downloadOverCellular", bundle: .module)
                        } icon: { Image(systemName: "antenna.radiowaves.left.and.right") }
                    }
                } footer: {
                    Text("settings.soundfont.cellularWarning", bundle: .module)
                }
            }
        }
        .navigationTitle(Text("settings.soundfont.title", bundle: .module))
        .navigationBarTitleDisplayMode(.inline)
        .task {
            isOptedIn = await provider.isOptedIn
            canUseCellular = true
            for await state in provider.downloadStateStream() {
                downloadState = state
            }
        }
    }

    private var isCurrentlyDownloaded: Bool {
        if case .downloaded = downloadState { return true }
        return false
    }

    @ViewBuilder
    private var stateFooter: some View {
        switch downloadState {
        case .idle:
            Text("settings.soundfont.state.idle", bundle: .module)
        case let .downloading(progress):
            VStack(alignment: .leading, spacing: 8) {
                Text("settings.soundfont.state.downloading", bundle: .module)
                ProgressView(value: progress)
            }
        case .downloaded:
            Text("settings.soundfont.state.downloaded", bundle: .module)
        case let .failed(reason):
            Text(verbatim: String(localized: "settings.soundfont.state.failed", bundle: .module) + " (\(reason))")
                .foregroundStyle(.red)
        }
    }
}
