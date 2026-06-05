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
    @Environment(\.dismiss) private var dismiss
    /// Transient Hz value written during a drag so the readout tracks the finger without committing on every frame.
    /// Committed to `globalA4Hz` (`@AppStorage`) on slider release.
    @State private var liveA4Hz: Double?
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

    @AppStorage(ReaderGlobalSettingsKey.showInvisibleElements)
    private var showInvisibleElements = false

    @AppStorage(ReaderGlobalSettingsKey.keepScreenAwakeEnabled)
    private var keepScreenAwake = true

    @AppStorage(ReaderGlobalSettingsKey.showSeekBarEnabled)
    private var showSeekBar = true

    @AppStorage(ReaderGlobalSettingsKey.a4ReferenceHz)
    private var globalA4Hz = A4Reference.standardHz

    @AppStorage(PrivacySettingsKey.crashReportingEnabled)
    private var isCrashReportingEnabled = true

    public init(
        provider: (any MuseScoreGeneralProvider)? = nil,
        versionHistoryLoader: any VersionHistoryLoader = DefaultVersionHistoryLoader(),
        onVersionHistoryViewed: @escaping @MainActor () -> Void = {},
        crashReporter: any CrashReporter = NoopCrashReporter(),
        @ViewBuilder licenseContent: @escaping () -> LicenseContent,
    ) {
        self.provider = provider
        self.versionHistoryLoader = versionHistoryLoader
        self.onVersionHistoryViewed = onVersionHistoryViewed
        self.crashReporter = crashReporter
        self.licenseContent = licenseContent
    }

    public var body: some View {
        NavigationStack {
            Form {
                readerSection
                privacySection
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
            Toggle(isOn: $showInvisibleElements) {
                Label {
                    Text("settings.reader.showInvisibleElements", bundle: .module)
                } icon: {
                    Image(systemName: showInvisibleElements ? "eye" : "eye.slash")
                }
            }
            keepScreenAwakeToggle
            seekBarToggle
            a4ReferenceRow
            readerLayoutRow
            if let provider {
                SoundfontPresetRow(provider: provider)
            }
        }
    }

    private var privacySection: some View {
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

    private var seekBarToggle: some View {
        Toggle(isOn: $showSeekBar) {
            Label {
                Text("settings.reader.showSeekBar", bundle: .module)
            } icon: {
                Image(systemName: "point.bottomleft.forward.to.point.topright.scurvepath")
            }
        }
    }

    /// Snap detents for the global A4 slider — same values as the per-score inspector.
    private let a4SnapDetents: [Double] = [432, 440]
    private let a4SnapRadius = 1.0

    private var a4ReferenceRow: some View {
        let displayHz = liveA4Hz ?? globalA4Hz
        let hzBinding = Binding<Double>(
            get: { displayHz },
            set: { liveA4Hz = $0 },
        )
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label {
                    Text("settings.playback.a4Reference.title", bundle: .module)
                } icon: {
                    Image(systemName: "tuningfork")
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 1) {
                    Text(String(format: "%.1f Hz", displayHz))
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.primary)
                    Text(String(format: "%+.1f¢", A4Reference.cents(forHz: displayHz)))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            Slider(
                value: hzBinding,
                in: A4Reference.minHz ... A4Reference.maxHz,
                onEditingChanged: { editing in
                    if !editing {
                        let raw = hzBinding.wrappedValue
                        let snapped = a4SnapDetents.first {
                            abs(raw - $0) <= a4SnapRadius
                        } ?? raw
                        globalA4Hz = A4Reference.clamp(snapped)
                        liveA4Hz = nil
                    }
                },
            )
            .tint(.accentColor)
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
