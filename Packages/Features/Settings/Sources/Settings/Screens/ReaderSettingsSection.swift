import Domain
import SwiftUI
import UtilityCore

/// The Settings sheet's reader section: playback toggles, the global A4 tuning slider, and the page-layout picker. Owns
/// the `@AppStorage`-backed reader globals it edits plus the transient `liveA4Hz` drag state, so the slider's readout
/// can track the finger without committing on every frame.
struct ReaderSettingsSection: View {
    let provider: (any MuseScoreGeneralProvider)?
    var analytics: any Analytics = NoopAnalytics()

    private var changeLog: SettingChangeLogger {
        SettingChangeLogger(analytics: analytics)
    }

    /// Transient Hz value written during a drag so the readout tracks the finger without committing on every frame.
    /// Committed to `globalA4Hz` (`@AppStorage`) on slider release.
    @State private var liveA4Hz: Double?

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
    @AppStorage(ReaderGlobalSettingsKey.repeatMode)
    private var repeatMode: RepeatMode = .off
    @AppStorage(ReaderGlobalSettingsKey.playlistContinuationMode)
    private var continuationMode: PlaylistContinuationMode = .playThrough
    @AppStorage(ReaderGlobalSettingsKey.a4ReferenceHz)
    private var globalA4Hz = A4Reference.standardHz

    var body: some View {
        Section {
            metronomeToggle
            pictureInPictureToggle
            collapseRestsToggle
            showInvisibleToggle
            keepScreenAwakeToggle
            seekBarToggle
            repeatModeRow
            playlistContinuationRow
            a4ReferenceRow
            readerLayoutRow
            if let provider {
                SoundfontPresetRow(provider: provider)
            }
        }
    }

    private var metronomeToggle: some View {
        Toggle(isOn: $isMetronomeEnabled) {
            Label {
                Text("settings.reader.metronome", bundle: .module)
            } icon: {
                Image(systemName: isMetronomeEnabled ? "metronome.fill" : "metronome")
            }
        }
        .onChange(of: isMetronomeEnabled) { _, value in changeLog.log(.metronome, value) }
    }

    private var collapseRestsToggle: some View {
        Toggle(isOn: $collapseMultiMeasureRests) {
            Label {
                Text("settings.reader.collapseMultiMeasureRests", bundle: .module)
            } icon: {
                Image(systemName: "rectangle.compress.vertical")
                    .rotationEffect(.degrees(90))
            }
        }
        .onChange(of: collapseMultiMeasureRests) { _, value in changeLog.log(.collapseMultiMeasureRests, value) }
    }

    private var showInvisibleToggle: some View {
        Toggle(isOn: $showInvisibleElements) {
            Label {
                Text("settings.reader.showInvisibleElements", bundle: .module)
            } icon: {
                Image(systemName: showInvisibleElements ? "eye" : "eye.slash")
            }
        }
        .onChange(of: showInvisibleElements) { _, value in changeLog.log(.showInvisibleElements, value) }
    }

    private var repeatModeRow: some View {
        RepeatModeSettingRow(mode: $repeatMode)
            .onChange(of: repeatMode) { _, value in changeLog.log(.repeatMode, value: value.analyticsValue) }
    }

    private var playlistContinuationRow: some View {
        PlaylistContinuationSettingRow(mode: $continuationMode)
            .onChange(of: continuationMode) { _, value in
                changeLog.log(.playlistContinuation, value: value.analyticsValue)
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
        .onChange(of: isPiPEnabled) { _, value in changeLog.log(.pictureInPicture, value) }
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
        .onChange(of: keepScreenAwake) { _, value in changeLog.log(.keepScreenAwake, value) }
    }

    private var seekBarToggle: some View {
        Toggle(isOn: $showSeekBar) {
            Label {
                Text("settings.reader.showSeekBar", bundle: .module)
            } icon: {
                Image(systemName: "point.bottomleft.forward.to.point.topright.scurvepath")
            }
        }
        .onChange(of: showSeekBar) { _, value in changeLog.log(.showSeekBar, value) }
    }

    /// Snap detents for the global A4 slider — same values as the per-score inspector.
    private let a4SnapDetents: [Double] = [432, 440]
    private let a4SnapRadius = 1.0

    private var a4ReferenceRow: some View {
        let displayHz = liveA4Hz ?? globalA4Hz
        // Integer Hz only — round every slider write.
        let hzBinding = Binding<Double>(
            get: { displayHz },
            set: { liveA4Hz = $0.rounded() },
        )
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label {
                    Text("settings.playback.a4Reference.title", bundle: .module)
                        .foregroundStyle(.primary)
                } icon: {
                    Image(systemName: "tuningfork")
                        .foregroundStyle(Color.accentColor)
                }
                Spacer()
                Text(String(format: "A4 = %dHz", Int(displayHz.rounded())))
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.primary)
            }
            Text("settings.playback.a4Reference.description", bundle: .module)
                .font(.caption)
                .foregroundStyle(.secondary)
            Slider(
                value: hzBinding,
                in: A4Reference.minHz ... A4Reference.maxHz,
                onEditingChanged: { editing in
                    if !editing {
                        let raw = hzBinding.wrappedValue
                        let snapped = a4SnapDetents.first {
                            abs(raw - $0) <= a4SnapRadius
                        } ?? raw
                        globalA4Hz = A4Reference.clamp(snapped.rounded())
                        liveA4Hz = nil
                    }
                },
            )
            .tint(.accentColor)
        }
        // `globalA4Hz` only changes on slider release, so this logs the committed integer Hz once per edit.
        .onChange(of: globalA4Hz) { _, value in changeLog.log(.a4Reference, value: String(Int(value.rounded()))) }
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
        .onChange(of: layoutModeRaw) { _, raw in
            changeLog.log(.layoutMode, value: ReaderLayoutMode(rawValue: raw)?.analyticsValue ?? raw)
        }
    }
}
