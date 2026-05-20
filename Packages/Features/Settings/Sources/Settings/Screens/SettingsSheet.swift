import Domain
import SwiftUI
import UtilityUI

@MainActor
public struct SettingsSheet<LicenseContent: View>: View {
    private let licenseContent: () -> LicenseContent
    private let provider: (any MuseScoreGeneralProvider)?
    private let versionHistoryLoader: any VersionHistoryLoader
    private let onVersionHistoryViewed: @MainActor () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var isFeedbackMailPresented = false
    @State private var feedbackMailResult: FeedbackMailComposeResult?
    @State private var isMailSavedAlertPresented = false
    @State private var isMailFailedAlertPresented = false

    @AppStorage(ReaderGlobalSettingsKey.metronomeEnabled)
    private var isMetronomeEnabled = false

    @AppStorage(ReaderGlobalSettingsKey.layoutMode)
    private var layoutModeRaw: String = ReaderLayoutMode.vertical.rawValue

    @AppStorage(ReaderGlobalSettingsKey.pictureInPictureEnabled)
    private var isPiPEnabled = false

    @AppStorage(ReaderGlobalSettingsKey.collapseMultiMeasureRests)
    private var collapseMultiMeasureRests = false

    @AppStorage(ReaderGlobalSettingsKey.keepScreenAwakeEnabled)
    private var keepScreenAwake = true

    public init(
        provider: (any MuseScoreGeneralProvider)? = nil,
        versionHistoryLoader: any VersionHistoryLoader = DefaultVersionHistoryLoader(),
        onVersionHistoryViewed: @escaping @MainActor () -> Void = {},
        @ViewBuilder licenseContent: @escaping () -> LicenseContent,
    ) {
        self.provider = provider
        self.versionHistoryLoader = versionHistoryLoader
        self.onVersionHistoryViewed = onVersionHistoryViewed
        self.licenseContent = licenseContent
    }

    public var body: some View {
        NavigationStack {
            Form {
                readerSection
                if let provider {
                    storageSection(provider: provider)
                }
                aboutSection
            }
            .navigationTitle(Text("settings.title", bundle: .module))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { doneToolbar }
            .sheet(isPresented: $isFeedbackMailPresented) {
                FeedbackMailView(result: $feedbackMailResult)
            }
            .alert(
                Text("settings.feedback.saved.title", bundle: .module),
                isPresented: $isMailSavedAlertPresented,
            ) {
                Button(role: .cancel) {} label: { L10n.Common.ok }
            }
            .alert(
                Text("settings.feedback.failed.title", bundle: .module),
                isPresented: $isMailFailedAlertPresented,
            ) {
                Button(role: .cancel) {} label: { L10n.Common.ok }
            }
            .onChange(of: feedbackMailResult) { _, newValue in
                switch newValue {
                case .saved:
                    isMailSavedAlertPresented = true
                case .failed:
                    isMailFailedAlertPresented = true
                case .cancelled, .sent, nil:
                    break
                }
            }
        }
    }

    private var readerSection: some View {
        Section {
            Toggle(isOn: $isMetronomeEnabled) {
                Label {
                    Text("settings.reader.metronome", bundle: .module)
                } icon: {
                    Image(systemName: isMetronomeEnabled ? "metronome.fill" : "metronome")
                }
            }
            Toggle(isOn: $isPiPEnabled) {
                Label {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("settings.reader.pictureInPicture", bundle: .module)
                        Text("settings.reader.pictureInPicture.footer", bundle: .module)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "pip")
                }
            }
            Toggle(isOn: $collapseMultiMeasureRests) {
                Label {
                    Text("settings.reader.collapseMultiMeasureRests", bundle: .module)
                } icon: {
                    Image(systemName: "rectangle.compress.vertical")
                        .rotationEffect(.degrees(90))
                }
            }
            Toggle(isOn: $keepScreenAwake) {
                Label {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("settings.reader.keepScreenAwake", bundle: .module)
                        Text("settings.reader.keepScreenAwake.footer", bundle: .module)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "lock.slash")
                }
            }
            readerLayoutRow
        } header: {
            Text("settings.reader.title", bundle: .module)
        }
    }

    private var readerLayoutRow: some View {
        HStack {
            Label {
                Text("settings.reader.layout.title", bundle: .module)
            } icon: {
                Image(systemName: "scroll")
            }
            Spacer()
            Picker(selection: $layoutModeRaw) {
                Image(systemName: "arrow.up.and.down")
                    .tag(ReaderLayoutMode.vertical.rawValue)
                Image(systemName: "arrow.left.and.right")
                    .tag(ReaderLayoutMode.horizontal.rawValue)
                Image(systemName: "book.pages")
                    .tag(ReaderLayoutMode.page.rawValue)
            } label: {
                Text("settings.reader.layout.title", bundle: .module)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 132)
            .fixedSize()
        }
    }

    private func storageSection(provider: any MuseScoreGeneralProvider) -> some View {
        Section {
            NavigationLink {
                SoundfontPresetView(provider: provider)
            } label: {
                Label {
                    Text("settings.soundfont.title", bundle: .module)
                } icon: {
                    Image(systemName: "tray.full")
                }
            }
        } header: {
            Text("settings.storage.title", bundle: .module)
        }
    }

    private var aboutSection: some View {
        Section {
            NavigationLink {
                versionHistoryDestination
                    .navigationTitle(Text("settings.versionHistory.title", bundle: .module))
                    .navigationBarTitleDisplayMode(.inline)
            } label: {
                Label {
                    Text("settings.versionHistory.title", bundle: .module)
                } icon: {
                    Image(systemName: "clock.arrow.circlepath")
                }
            }

            NavigationLink {
                licenseContent()
                    .navigationTitle(Text("settings.about.licenses", bundle: .module))
                    .navigationBarTitleDisplayMode(.inline)
            } label: {
                Label {
                    Text("settings.about.licenses", bundle: .module)
                } icon: {
                    Image(systemName: "doc.text")
                }
            }

            Button {
                isFeedbackMailPresented = true
            } label: {
                Label {
                    Text("settings.about.sendFeedback", bundle: .module)
                } icon: {
                    Image(systemName: "envelope")
                }
            }
            .disabled(!FeedbackMailView.canSendMail)
        } header: {
            Text("settings.about.title", bundle: .module)
        }
    }

    @ViewBuilder
    private var versionHistoryDestination: some View {
        if let entries = try? versionHistoryLoader.load() {
            VersionHistoryScreen(
                viewModel: VersionHistoryViewModel(
                    entries: entries,
                    baseline: .zero,
                    isHistorySplit: false,
                ),
                onAppear: onVersionHistoryViewed,
            )
        } else {
            ContentUnavailableView {
                Label {
                    Text("settings.versionHistory.empty", bundle: .module)
                } icon: {
                    Image(systemName: "exclamationmark.triangle")
                }
            }
        }
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

private struct _StubProvider: MuseScoreGeneralProvider {
    var isOptedIn: Bool {
        true
    }

    var isDownloaded: Bool {
        false
    }

    var museScoreGeneralFileURL: URL? {
        nil
    }

    var museScoreGeneralFileURLSync: URL? {
        nil
    }

    var currentPreset: SoundfontPreset {
        .lightweight
    }

    func setOptedIn(_: Bool) {}
    func downloadStateStream() -> AsyncStream<SoundfontDownloadState> {
        AsyncStream { _ in }
    }

    func startDownloadIfNeeded() {}
    func startDownloadAllowingCellular() {}
    func cancelDownload() {}
    func deleteDownloaded() {}
}
