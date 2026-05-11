import Domain
import SheetMusicAudio
import SheetMusicCore
import SwiftUI

struct PlaybackInspectorScreen: View {
    @Bindable var viewModel: ReaderViewModel
    let score: Score

    @AppStorage(ReaderGlobalSettingsKey.metronomeEnabled) private var isMetronomeEnabled: Bool = false
    /// Slider's local edit value. Syncs from `viewModel.effectiveTempoMultiplier`
    /// when the user is not dragging — keeps the UI consistent after a reset
    /// from outside the slider (e.g. the % label tap).
    @State private var sliderValue: Double = 1.0
    @State private var isEditingTempo: Bool = false

    var body: some View {
        List {
            // Top-of-list "general" controls intentionally render without
            // a section header — they apply to the whole score and the
            // header would only repeat that with no information value.
            tempoControls
            HStack {
                Text("reader.inspector.repeatMode", bundle: .module)
                Spacer()
                RepeatModePicker(selection: $viewModel.repeatMode)
            }

            Section {
                ForEach(score.parts.indices, id: \.self) { partIndex in
                    let part = score.parts[partIndex]
                    VStack {
                        HStack {
                            Text(part.instrument.longName ?? part.trackName ?? "-")
                                .font(.headline)

                            ProgramPicker(viewModel: viewModel, partIndex: partIndex)
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
        .task(id: viewModel.effectiveTempoMultiplier) {
            // Pull the persisted value into the slider whenever the model
            // changes from outside the gesture (initial load, % tap reset).
            if !isEditingTempo {
                sliderValue = viewModel.effectiveTempoMultiplier
            }
        }
    }

    private var tempoControls: some View {
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
                Task { await viewModel.resetTempoMultiplier() }
            } label: {
                Text("\(Int((sliderValue * 100).rounded()))%")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.primary)
                    .frame(minWidth: 44, alignment: .trailing)
            }

            Slider(
                value: $sliderValue,
                in: 0.5 ... 2.0,
                onEditingChanged: { editing in
                    isEditingTempo = editing
                    if !editing {
                        Task { await viewModel.commitTempoMultiplier(sliderValue) }
                    }
                },
            )
            .onChange(of: sliderValue) { _, newValue in
                if isEditingTempo {
                    viewModel.setTempoMultiplier(newValue)
                }
            }
            .padding(.vertical, -8)
        }
    }

    @ViewBuilder
    private func staffRow(address: StaffAddress) -> some View {
        let volumeBinding = Binding<Double>(
            get: { viewModel.volume(for: address) },
            set: { viewModel.setVolume($0, for: address) },
        )
        let isMuted = viewModel.mutedStaves.contains(address)
        let isSolo = viewModel.soloStaves.contains(address)
        let isDisabled = isMuted || !viewModel.soloStaves.isEmpty && !isSolo
        HStack {
            Image(systemName: "speaker.wave.2.fill")
                .foregroundStyle(isDisabled ? .gray.opacity(0.6) : .accentColor)

            Slider(
                value: volumeBinding,
                in: 0 ... 1,
                onEditingChanged: { editing in
                    if !editing {
                        let final = volumeBinding.wrappedValue
                        Task { await viewModel.commitVolume(final, for: address) }
                    }
                },
            )
            .tint(isDisabled ? .gray : Color.accentColor)
            .disabled(isDisabled)

            Button {
                viewModel.toggleStaffSolo(address: address)
            } label: {
                Image(systemName: isSolo ? "s.circle.fill" : "s.circle")
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 24, height: 24)
            }

            Button {
                viewModel.toggleStaffMute(address: address)
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

private enum InspectorTab: Hashable {
    case playback
    case visual
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
            PlaybackInspectorScreen(viewModel: vm, score: score)
        }
}
#endif
