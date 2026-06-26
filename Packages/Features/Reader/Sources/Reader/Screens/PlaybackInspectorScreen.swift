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
    /// Live playback cursor. The tempo readout reads the score's effective tempo here so it tracks mid-score tempo
    /// changes; `nil` (no cursor yet) resolves to the opening tempo.
    let playbackCursor: ScoreCursor?
    /// True when the Reader was opened from a playlist — gates whether the continuation row is shown.
    let isInPlaylist: Bool

    @AppStorage(ReaderGlobalSettingsKey.metronomeEnabled) private var isMetronomeEnabled = false
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
                ForEach(Array(score.parts.enumerated()), id: \.element.id) { partIndex, part in
                    VStack {
                        HStack {
                            Text(part.instrument.longName ?? part.trackName ?? "-")
                                .font(.headline)

                            ProgramPicker(
                                mixerModel: mixerModel,
                                partIndex: partIndex,
                                isDrums: part.instrument.useDrumset,
                            )
                        }

                        VStack {
                            ForEach(staffAddresses(part, partIndex: partIndex), id: \.self) { address in
                                staffRow(address: address)
                            }
                        }
                    }
                    .listRowInsets(.vertical, 8)
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
                tempoReadoutLine(referenceBpm: referenceBpm, minBpm: minBpm, maxBpm: maxBpm)
                tempoSliderLine(referenceBpm: referenceBpm, minBpm: minBpm, maxBpm: maxBpm)
            }
        }
    }

    /// Top line of the tempo row: the engraved beat marking (glyph + value, tap to reset) and the ± stepper.
    /// The marking governing the cursor supplies the beat note + printed value; `cursorTempoKey` (the section's quarter
    /// bps) keys the roll animation — it changes only on a score-origin tempo change, not a slider / stepper edit.
    @ViewBuilder
    private func tempoReadoutLine(referenceBpm: Double, minBpm: Double, maxBpm: Double) -> some View {
        // Stepper bumps the reference BPM by 1 and commits — one notch == one whole BPM at the opening tempo.
        let stepperBpm = Binding<Double>(
            get: { (tempoModel.displayMultiplier * referenceBpm).rounded() },
            set: { newValue in
                let clamped = min(max(newValue.rounded(), minBpm), maxBpm)
                Task { await tempoModel.commitMultiplier(clamped / referenceBpm) }
            },
        )
        let governing = score.governingTempo(at: playbackCursor)
        let beatGlyph = governing?.beatGlyph ?? "\u{E1D5}"
        let beatValue = Int(((governing?.beatsPerMinute ?? 120) * tempoModel.displayMultiplier).rounded())
        let cursorTempoKey = governing?.beatsPerSecond ?? 2.0
        // The readout/reset Button rides in the Stepper's own label so the List treats this as a labeled form row and
        // gives the `−`/`+` the light `tertiarySystemFill`, matching the staff-size / transpose steppers. A bare
        // `.labelsHidden()` Stepper renders as a standalone control with a darker fill that read as inconsistent.
        Stepper(value: stepperBpm, in: minBpm ... maxBpm, step: 1) {
            HStack(spacing: 8) {
                Button {
                    Task { await tempoModel.resetMultiplier() }
                } label: {
                    HStack(spacing: 4) {
                        TempoBeatGlyph(glyph: beatGlyph, fontSize: 18)
                        Text(verbatim: "= \(beatValue)")
                            .font(.callout.monospacedDigit())
                            .foregroundStyle(.primary)
                            .contentTransition(.numericText(value: Double(beatValue)))
                    }
                    .animation(.default, value: cursorTempoKey)
                }
                Spacer()
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

    /// Staff addresses for a part, used as the inner ForEach identity (stable per staff, unlike a position index).
    private func staffAddresses(_ part: Part, partIndex: Int) -> [StaffAddress] {
        part.staves.indices.map { StaffAddress(partIndex: partIndex, staffIndexInPart: $0) }
    }

    @ViewBuilder
    private func staffRow(address: StaffAddress) -> some View {
        let volumeBinding = Binding<Double>(
            get: { mixerModel.volume(for: address) },
            set: { mixerModel.setVolume($0, for: address) },
        )
        let isMuted = mixerModel.mutedStaves.contains(address)
        let isSolo = mixerModel.soloStaves.contains(address)
        let isDisabled = isMuted || !mixerModel.soloStaves.isEmpty && !isSolo
        let defaultVolume = mixerModel.defaultVolume(for: address)
        HStack {
            Image(systemName: "speaker.wave.2.fill")
                .foregroundStyle(isDisabled ? .gray.opacity(0.6) : .accentColor)

            ResettableSlider(
                value: volumeBinding,
                range: 0 ... 1,
                defaultValue: defaultVolume,
                onEditingChanged: { editing in
                    if !editing {
                        let final = volumeBinding.wrappedValue
                        Task { await mixerModel.commitVolume(final, for: address) }
                    }
                },
                onReset: {
                    Task { await mixerModel.commitVolume(defaultVolume, for: address) }
                },
            )
            .tint(isDisabled ? .gray : Color.accentColor)
            .disabled(isDisabled)

            Button(String("S")) {
                mixerModel.toggleStaffSolo(address)
            }
            .fontWeight(.medium)
            .buttonStyle(CircleBorderedToggleButtonStyle(isOn: isSolo))
            .accessibilityLabel(Text("reader.inspector.staffSolo", bundle: .module))

            Button(String("M")) {
                mixerModel.toggleStaffMute(address)
            }
            .fontWeight(.medium)
            .buttonStyle(CircleBorderedToggleButtonStyle(isOn: isMuted))
            .accessibilityLabel(Text("reader.inspector.staffMute", bundle: .module))

            StaffVisibilityButton(layoutModel: layoutModel, address: address)
        }
    }
}

#if DEBUG
#Preview {
    let score = Score(
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
        ],
        metaTags: [:],
    )
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
                mixerModel: vm.mixerModel,
                layoutModel: vm.layoutModel,
                tempoModel: vm.tempoModel,
                masterVolumeModel: vm.masterVolumeModel,
                a4ReferenceModel: vm.a4ReferenceModel,
                repeatModel: vm.repeatModel,
                transposeModel: vm.transposeModel,
                score: score,
                playbackCursor: vm.playbackSession.playbackCursor,
                isInPlaylist: true,
            )
        }
}
#endif
