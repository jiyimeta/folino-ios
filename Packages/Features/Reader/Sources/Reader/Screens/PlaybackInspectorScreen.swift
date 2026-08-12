import Domain
import Foundation
import SheetMusicAudio
import SheetMusicCore
import SheetMusicLayoutApple
import SwiftUI
import UtilityUI

/// Master-volume slider taper. The slider's value space is position `0…1`; linear amplitude is
/// `position^N × maxMasterVolume`. Squaring (N = 2) sits between a strict-log dB taper (which can't
/// include silence at 0) and a linear taper. It spreads the perceptually-important attenuation
/// range across the lower half of the track and lands unity (amplitude 1.0) at position √(1/3) ≈
/// 0.577 — about 58% along the slider — so the boost region (100 %–300 %) gets the upper ~42 %.
/// N also matches Stevens' loudness exponent fairly well (perceived loudness ≈ amp^0.67, inverse
/// ≈ 1.5; we use 2 because slightly steeper feels more natural for a single-finger drag at the
/// soft end). The model continues to store / forward linear amplitude; only the slider's spatial
/// mapping changes.
private let masterVolumeCurveExponent = 2.0

private func masterVolumeAmplitude(forSliderPosition position: Double) -> Double {
    let clamped = min(max(position, 0), 1)
    return pow(clamped, masterVolumeCurveExponent) * ReaderPreferences.maxMasterVolume
}

private func masterVolumeSliderPosition(forAmplitude amplitude: Double) -> Double {
    let clamped = min(
        max(amplitude, ReaderPreferences.minMasterVolume),
        ReaderPreferences.maxMasterVolume,
    )
    let normalized = clamped / ReaderPreferences.maxMasterVolume
    return pow(normalized, 1.0 / masterVolumeCurveExponent)
}

struct PlaybackInspectorScreen: View {
    let mixerModel: PlaybackMixerModel
    let layoutModel: LayoutSettingsModel
    let tempoModel: TempoModel
    let masterVolumeModel: MasterVolumeModel
    let a4ReferenceModel: A4ReferenceModel
    @Bindable var repeatModel: RepeatModel
    let transposeModel: TransposeModel
    let score: Score
    /// The live playback session. Only the tempo readout observes its `playbackCursor`, and it does so from the
    /// isolated `TempoReadoutLine` leaf — NOT from this screen's `body`. Reading the high-frequency cursor here would
    /// rebuild the whole inspector `List` every note during playback, which interrupted scrolling of the per-part
    /// program `Menu`. Passing the session as a plain reference (never reading `.playbackCursor` in `body`) keeps the
    /// per-tick invalidation confined to the leaf.
    let playbackSession: ReaderPlaybackSession
    /// True when the Reader was opened from a playlist — gates whether the continuation row is shown.
    let isInPlaylist: Bool
    /// Whether each staff row carries the show/hide eye. Every other control here drives the engine and so applies
    /// verbatim to a playable PDF, but staff visibility re-derives the *rendered* score — which a fixed-layout PDF
    /// can't do — so the PDF reader opts out.
    var showsStaffVisibility = true

    @AppStorage(ReaderGlobalSettingsKey.metronomeEnabled) private var isMetronomeEnabled = false
    @AppStorage(ReaderGlobalSettingsKey.precountEnabled) private var isPrecountEnabled = false
    @AppStorage(ReaderGlobalSettingsKey.playlistContinuationMode)
    private var continuationMode: PlaylistContinuationMode = .playThrough

    @AppStorage("reader.inspector.playback.general.expanded") private var generalExpanded = true
    @AppStorage("reader.inspector.playback.parts.expanded") private var partsExpanded = true

    var body: some View {
        List {
            // Whole-score transport / mix controls live in one section above the per-part mixer. Each row's distinct
            // icon (metronome / tempo gauge / repeat / speaker) keeps them readable without further separators.
            CollapsibleSection(isExpanded: $generalExpanded) {
                metronomeRow
                precountRow
                tempoRow
                repeatModeRow
                if isInPlaylist {
                    continuationRow
                }
                masterVolumeRow
                TransposeRow(transposeModel: transposeModel)
                a4ReferenceRow
            } header: {
                Text("reader.inspector.section.general", bundle: .module)
            }

            CollapsibleSection(isExpanded: $partsExpanded) {
                ForEach(mixerModel.strips.grouped(), id: \.partIndex) { group in
                    let staves = staffAddresses(partIndex: group.partIndex)
                    VStack {
                        if group.drawsHeader(staffCount: staves.count) {
                            partHeader(group, staves: staves)
                            ForEach(group.strips) { strip in
                                stripRow(strip, label: group.rowLabel(for: strip), staves: [])
                            }
                        } else {
                            // One strip, one staff: everything on one row, the shape the mixer has always had.
                            stripRow(group.strips[0], label: group.partName, staves: staves)
                        }
                    }
                    .verticalRowInsetCompat(8)
                }
            } header: {
                Text("reader.inspector.section.parts", bundle: .module)
            }
        }
        .contentMargins(.top, 4, for: .scrollContent)
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var masterVolumeRow: some View {
        // The slider operates in position space (0…1) so the linear-amplitude axis stretches non-linearly along the
        // track — `amplitude = position² × maxMasterVolume`. The model still stores linear amplitude, and the percent
        // readout below is the plain `amplitude × 100`. See `masterVolumeAmplitude(forSliderPosition:)` for why N=2.
        let positionBinding = Binding<Double>(
            get: { masterVolumeSliderPosition(forAmplitude: masterVolumeModel.displayValue) },
            set: { masterVolumeModel.setValue(masterVolumeAmplitude(forSliderPosition: $0)) },
        )
        let unityPosition = masterVolumeSliderPosition(forAmplitude: 1.0)
        HStack(spacing: 8) {
            Image(systemName: "speaker.wave.3.fill")
                .foregroundStyle(Color.accentColor)
            Text("reader.inspector.masterVolume", bundle: .module)

            Button {
                Task { await masterVolumeModel.resetValue() }
            } label: {
                Text("\(Int((masterVolumeModel.displayValue * 100).rounded()))%")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.primary)
                    .frame(minWidth: 44, alignment: .trailing)
            }

            ResettableSlider(
                value: positionBinding,
                range: 0 ... 1,
                defaultValue: unityPosition,
                onEditingChanged: { editing in
                    if !editing {
                        let final = masterVolumeAmplitude(forSliderPosition: positionBinding.wrappedValue)
                        Task { await masterVolumeModel.commitValue(final) }
                    }
                },
                onReset: {
                    Task { await masterVolumeModel.resetValue() }
                },
            )
        }
    }

    private var repeatModeRow: some View {
        HStack {
            Image(systemName: "repeat")
                .foregroundStyle(Color.accentColor)
            Text("reader.inspector.repeatMode", bundle: .module)
                .layoutPriority(1)
            Spacer(minLength: 8)
            RepeatModePicker(selection: $repeatModel.mode)
                .onChange(of: repeatModel.mode) { _, _ in
                    ReaderHintCoordinator.shared.markUsed(.repeatPlayback)
                }
        }
    }

    @ViewBuilder
    private var continuationRow: some View {
        // The continuation control is subordinate to per-score repeat: when repeat is looping this score it is
        // disabled, with a caption explaining why playback won't advance.
        let repeatActive = repeatModel.mode != .off
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: "music.note.list")
                    .foregroundStyle(Color.accentColor)
                Text("reader.inspector.continuation", bundle: .module)
                    .layoutPriority(1)
                Spacer(minLength: 8)
                PlaylistContinuationPicker(selection: $continuationMode)
                    .disabled(repeatActive)
            }
            if repeatActive {
                Text("reader.inspector.continuation.repeatActive", bundle: .module)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var tempoRow: some View {
        // The slider works in absolute BPM space, stepped at whole beats-per-minute and anchored to the score's opening
        // tempo (`referenceBpm`), so a drag lands on round BPM there. `tempoModel` still stores a unitless multiplier
        // (bpm / referenceBpm), so persistence is unchanged — only the slider's value axis and the label switch to BPM.
        //
        // The readout, though, renders the marking *governing the cursor* as engraved — its beat glyph and beat-unit
        // value (e.g. "♩ = 158" or, in a 6/8 section, "♩. = 120") — multiplied by the playback multiplier so it tracks
        // both the live rate and mid-score tempo changes. The grey "<percent>%" line below stays put with the thumb.
        //
        // Route the slider's binding through `tempoModel` (like the per-staff volume sliders go through `mixerModel`)
        // so the slider's release-time writeback lands in the model's transient `liveMultiplier` and `commitMultiplier`
        // / `resetMultiplier` can authoritatively clear it — a slider double-tap reset against a plain `@Binding` to
        // local `@State` is overwritten by the writeback and silently reverts.
        let referenceBpm = max(1, score.effectiveQuarterBpm(at: nil))
        let minBpm = (referenceBpm * ReaderPreferences.minTempoMultiplier).rounded()
        let maxBpm = (referenceBpm * ReaderPreferences.maxTempoMultiplier).rounded()
        HStack(spacing: 8) {
            Image(systemName: "gauge.open.with.lines.needle.33percent")
                .foregroundStyle(Color.accentColor)

            // `spacing: 8` (not 4) keeps the slider's thumb on the lower line clear of the `−`/`+` stepper above it —
            // at the tighter spacing the thumb's circle visually grazed the stepper when the value sat near the top.
            VStack(alignment: .leading, spacing: 8) {
                TempoReadoutLine(
                    tempoModel: tempoModel,
                    session: playbackSession,
                    score: score,
                    referenceBpm: referenceBpm,
                    minBpm: minBpm,
                    maxBpm: maxBpm,
                )
                tempoSliderLine(referenceBpm: referenceBpm, minBpm: minBpm, maxBpm: maxBpm)
            }
        }
    }

    /// Bottom line of the tempo row: the grey percentage readout and the whole-BPM slider.
    @ViewBuilder
    private func tempoSliderLine(referenceBpm: Double, minBpm: Double, maxBpm: Double) -> some View {
        let bpmBinding = Binding<Double>(
            get: { tempoModel.displayMultiplier * referenceBpm },
            set: { tempoModel.setMultiplier($0 / referenceBpm) },
        )
        let percent = Int((tempoModel.displayMultiplier * 100).rounded())
        HStack(spacing: 8) {
            Text(verbatim: "\(percent)%")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(minWidth: 40, alignment: .leading)

            ResettableSlider(
                value: bpmBinding,
                range: minBpm ... maxBpm,
                defaultValue: referenceBpm,
                step: 1,
                onEditingChanged: { editing in
                    if !editing {
                        Task { await tempoModel.commitMultiplier(bpmBinding.wrappedValue / referenceBpm) }
                    }
                },
                onReset: {
                    Task { await tempoModel.resetMultiplier() }
                },
            )
        }
    }

    private var metronomeRow: some View {
        Toggle(isOn: $isMetronomeEnabled) {
            HStack {
                Image(systemName: isMetronomeEnabled ? "metronome.fill" : "metronome")
                    .foregroundStyle(Color.accentColor)
                Text("reader.inspector.metronome", bundle: .module)
            }
        }
    }

    private var precountRow: some View {
        Toggle(isOn: $isPrecountEnabled) {
            HStack {
                Image(systemName: "timer")
                    .foregroundStyle(Color.accentColor)
                Text("reader.inspector.precount", bundle: .module)
            }
        }
    }
}

#if DEBUG
/// Strips covering the three shapes the parts section can draw. Their `partIndex`es line up with the preview score's
/// parts, so each group's staff count is the one the real inspector would see.
private let previewMixerStrips: [MixerStrip] = [
    // Part 0 — one strip over one staff: collapses to a single row carrying its own eye.
    MixerStrip(
        id: MixerStripID(partIndex: 0, instrumentOrdinal: 0),
        partName: "Violin", instrumentName: "Violin",
        defaultVolume: 0.8, defaultProgram: 40, isDrums: false,
    ),
    // Part 1 — one strip over TWO staves (a grand staff): a header with two eyes over one unlabelled row.
    MixerStrip(
        id: MixerStripID(partIndex: 1, instrumentOrdinal: 0),
        partName: "Piano", instrumentName: "Piano",
        defaultVolume: 0.8, defaultProgram: 0, isDrums: false,
    ),
    // Part 2 — TWO strips over one staff: a header with one eye over two labelled rows, the drum one offering the
    // kit catalog rather than the melodic one.
    MixerStrip(
        id: MixerStripID(partIndex: 2, instrumentOrdinal: 0),
        partName: "Percussion", instrumentName: "Drum Kit",
        defaultVolume: 0.9, defaultProgram: 0, isDrums: true,
    ),
    MixerStrip(
        id: MixerStripID(partIndex: 2, instrumentOrdinal: 1),
        partName: "Percussion", instrumentName: "Timpani",
        defaultVolume: 0.7, defaultProgram: 47, isDrums: false,
    ),
]

/// Staff counts to match: one, two (a grand staff), one. The instruments here are only what a score would author —
/// what the mixer draws comes from `previewMixerStrips`.
private let previewMixerScore = Score(
    division: 480,
    parts: [
        Part(
            id: "P0", trackName: "Violin", // GM 40 = Violin
            instrument: Instrument(id: "violin", channels: [InstrumentChannel(program: 40)]),
            staves: [Staff()],
        ),
        Part(
            id: "P1", trackName: "Piano", // GM 0 = Acoustic Grand Piano
            instrument: Instrument(id: "piano", channels: [InstrumentChannel(program: 0)]),
            staves: [Staff(), Staff()],
        ),
        Part(
            id: "P2", trackName: "Percussion",
            instrument: Instrument(id: "percussion", channels: [InstrumentChannel(program: 0)]),
            staves: [Staff()],
        ),
    ],
    metaTags: [:],
)

#Preview {
    let score = previewMixerScore
    let vm = ReaderViewModel(
        scoreItem: PreviewFakeRepository.sampleItem,
        repository: PreviewFakeRepository(),
        gateway: PreviewFakeGateway(score: score),
        scoresDirectory: URL(filePath: "/tmp"),
    )
    Text("Contents")
        .task { await vm.load() }
        .sheet(isPresented: .constant(true)) {
            PlaybackInspectorScreen(
                mixerModel: .previewModel(strips: previewMixerStrips),
                layoutModel: vm.layoutModel,
                tempoModel: vm.tempoModel,
                masterVolumeModel: vm.masterVolumeModel,
                a4ReferenceModel: vm.a4ReferenceModel,
                repeatModel: vm.repeatModel,
                transposeModel: vm.transposeModel,
                score: score,
                playbackSession: vm.playbackSession,
                isInPlaylist: true,
            )
        }
}
#endif
