import Domain
import SheetMusicAudio
import SheetMusicCore
import SwiftUI

struct PlaybackInspectorScreen: View {
    let mixerModel: PlaybackMixerModel
    let tempoModel: TempoModel
    @Bindable var repeatModel: RepeatModel
    let score: Score

    @AppStorage(ReaderGlobalSettingsKey.metronomeEnabled) private var isMetronomeEnabled = false

    var body: some View {
        List {
            // Top-of-list "general" controls intentionally render without
            // a section header — they apply to the whole score and the
            // header would only repeat that with no information value.
            tempoControls
            HStack {
                Text("reader.inspector.repeatMode", bundle: .module)
                Spacer()
                RepeatModePicker(selection: $repeatModel.mode)
            }

            Section {
                ForEach(score.parts.indices, id: \.self) { partIndex in
                    let part = score.parts[partIndex]
                    VStack {
                        HStack {
                            Text(part.instrument.longName ?? part.trackName ?? "-")
                                .font(.headline)

                            ProgramPicker(mixerModel: mixerModel, partIndex: partIndex)
                        }

                        VStack {
                            ForEach(part.staves.indices, id: \.self) { staffIndex in
                                staffRow(address: StaffAddress(partIndex: partIndex, staffIndexInPart: staffIndex))
                            }
                        }
                    }
                    .listRowInsets(.vertical, 8)
                }
            } header: {
                Text("reader.inspector.section.parts", bundle: .module)
            }
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var tempoControls: some View {
        // Route the slider's binding through `tempoModel` (like the per-staff
        // volume sliders go through `mixerModel`) so the slider's release-
        // time writeback lands in the model's transient `liveMultiplier` and
        // `commitMultiplier` / `resetMultiplier` can authoritatively clear
        // it — a slider double-tap reset against a plain `@Binding` to local
        // `@State` is overwritten by the writeback and silently reverts.
        let tempoBinding = Binding<Double>(
            get: { tempoModel.displayMultiplier },
            set: { tempoModel.setMultiplier($0) },
        )
        HStack(spacing: 8) {
            Button {
                isMetronomeEnabled.toggle()
            } label: {
                Image(systemName: isMetronomeEnabled ? "metronome.fill" : "metronome")
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 24, height: 24)
                    .padding(.horizontal, 4)
            }

            Button {
                Task { await tempoModel.resetMultiplier() }
            } label: {
                Text("\(Int((tempoModel.displayMultiplier * 100).rounded()))%")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.primary)
                    .frame(minWidth: 44, alignment: .trailing)
            }

            ResettableSlider(
                value: tempoBinding,
                range: 0.5 ... 2.0,
                defaultValue: 1.0,
                onEditingChanged: { editing in
                    if !editing {
                        let final = tempoBinding.wrappedValue
                        Task { await tempoModel.commitMultiplier(final) }
                    }
                },
                onReset: {
                    Task { await tempoModel.resetMultiplier() }
                },
            )
        }
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

            Button {
                mixerModel.toggleStaffSolo(address)
            } label: {
                Image(systemName: isSolo ? "s.circle.fill" : "s.circle")
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 24, height: 24)
            }

            Button {
                mixerModel.toggleStaffMute(address)
            } label: {
                Image(systemName: isMuted ? "m.circle.fill" : "m.circle")
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 24, height: 24)
            }
        }
    }
}

#if DEBUG
#Preview {
    let score = Score(
        division: 480,
        parts: [
            Part(
                id: "P0",
                trackName: "Violin",
                instrument: Instrument(
                    id: "violin",
                    channels: [InstrumentChannel(program: 40)], // GM 40 = Violin
                ),
                staves: [Staff()],
            ),
            Part(
                id: "P1",
                trackName: "Piano",
                instrument: Instrument(
                    id: "piano",
                    channels: [InstrumentChannel(program: 0)], // GM 0 = Acoustic Grand Piano
                ),
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
                tempoModel: vm.tempoModel,
                repeatModel: vm.repeatModel,
                score: score,
            )
        }
}
#endif
