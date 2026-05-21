import Domain
import Observation
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
    private var layoutModeRaw: String = ReaderLayoutMode.page.rawValue

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
            pictureInPictureToggle
            Toggle(isOn: $collapseMultiMeasureRests) {
                Label {
                    Text("settings.reader.collapseMultiMeasureRests", bundle: .module)
                } icon: {
                    Image(systemName: "rectangle.compress.vertical")
                        .rotationEffect(.degrees(90))
                }
            }
            keepScreenAwakeToggle
            readerLayoutRow
            if let provider {
                SoundfontPresetRow(provider: provider)
            }
        }
    }

    private var pictureInPictureToggle: some View {
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
    }

    private var keepScreenAwakeToggle: some View {
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
