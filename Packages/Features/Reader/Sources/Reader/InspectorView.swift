import SheetMusicAudio
import SheetMusicCore
import SwiftUI

struct InspectorView: View {
    @Bindable var viewModel: ReaderViewModel
    let score: Score

    @AppStorage("readerMetronomeEnabled") private var isMetronomeEnabled: Bool = false
    /// Slider's local edit value. Syncs from `viewModel.effectiveTempoMultiplier`
    /// when the user is not dragging — keeps the UI consistent after a reset
    /// from outside the slider (e.g. the % label tap).
    @State private var sliderValue: Double = 1.0
    @State private var isEditingTempo: Bool = false
    @Environment(\.horizontalSizeClass) private var hsc
    @State private var selectedTab: InspectorTab = .playback

    var body: some View {
        Group {
            if hsc == .compact {
                VStack(spacing: 0) {
                    Picker("Inspector tab", selection: $selectedTab) {
                        Text("Playback").tag(InspectorTab.playback)
                        Text("Visual").tag(InspectorTab.visual)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .padding(.horizontal)
                    .padding(.top, 16)

                    switch selectedTab {
                    case .playback:
                        tabList { playbackContent }
                    case .visual:
                        tabList { visualContent }
                    }
                }
            } else {
                List {
                    Section("Playback") { playbackContent }
                    Section("Visual") { visualContent }
                }
                .listStyle(.plain)
                .buttonStyle(.plain)
                .padding(.top, 16)
                .environment(\.defaultMinListRowHeight, 28)
            }
        }
        .task(id: viewModel.effectiveTempoMultiplier) {
            // Pull the persisted value into the slider whenever the model
            // changes from outside the gesture (initial load, % tap reset).
            if !isEditingTempo {
                sliderValue = viewModel.effectiveTempoMultiplier
            }
        }
        .task {
            await viewModel.setMetronomeEnabled(isMetronomeEnabled)
        }
    }

    @ViewBuilder
    private func tabList<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        List { content() }
            .listStyle(.plain)
            .buttonStyle(.plain)
            .environment(\.defaultMinListRowHeight, 28)
    }

    @ViewBuilder
    private var playbackContent: some View {
        tempoRow
        ForEach(score.parts.indices, id: \.self) { partIndex in
            let part = score.parts[partIndex]
            Section {
                ForEach(part.staves.indices, id: \.self) { staffIndex in
                    staffRow(address: StaffAddress(partIndex: partIndex, staffIndexInPart: staffIndex))
                }
            } header: {
                Text(part.instrument.longName ?? part.trackName ?? "-")
                    .font(.headline)
                    .padding(.bottom, -8)
            }
            .headerProminence(.increased)
            .padding(.bottom, -8)
        }
    }

    @ViewBuilder
    private var visualContent: some View {
        Section {
            Picker("Layout", selection: $viewModel.layoutMode) {
                Text("Vertical").tag(ReaderViewModel.LayoutMode.vertical)
                Text("Horizontal").tag(ReaderViewModel.LayoutMode.horizontal)
            }
            .pickerStyle(.segmented)
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
        }
    }

    @ViewBuilder
    private var tempoRow: some View {
        Section {
            tempoControls
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
        }
    }

    @ViewBuilder
    private var tempoControls: some View {
        HStack(spacing: 8) {
            Button {
                isMetronomeEnabled.toggle()
                Task { await viewModel.setMetronomeEnabled(isMetronomeEnabled) }
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
                }
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
            set: { viewModel.setVolume($0, for: address) }
        )
        let isMuted = viewModel.mutedStaves.contains(address)
        let isSolo = viewModel.soloStaves.contains(address)
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Slider(value: volumeBinding, in: 0 ... 1)
                    .disabled(isMuted || !viewModel.soloStaves.isEmpty && !isSolo)
                    .padding(.vertical, -8)

                Button {
                    viewModel.toggleStaffSolo(address: address)
                } label: {
                    Image(systemName: isSolo ? "s.circle.fill" : "s.circle")
                        .resizable()
                        .scaledToFit()
                        .foregroundStyle(Color.accentColor)
                        .frame(width: 24, height: 24)
                        .padding(.horizontal, 4)
                }

                Button {
                    viewModel.toggleStaffMute(address: address)
                } label: {
                    Image(systemName: isMuted ? "m.circle.fill" : "m.circle")
                        .resizable()
                        .scaledToFit()
                        .foregroundStyle(Color.accentColor)
                        .frame(width: 24, height: 24)
                        .padding(.horizontal, 4)
                }
                visibilityButton(address: address)
            }
            programPicker(address: address)
        }
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
    }

    @ViewBuilder
    private func programPicker(address: StaffAddress) -> some View {
        let program = viewModel.effectiveProgram(for: address)
        let hasOverride = viewModel.hasProgramOverride(for: address)
        HStack(spacing: 6) {
            Image(systemName: "music.note.list")
                .foregroundStyle(.secondary)
            Menu {
                if hasOverride {
                    Button {
                        Task { await viewModel.clearStaffProgramOverride(for: address) }
                    } label: {
                        Label("Reset to default", systemImage: "arrow.uturn.backward")
                    }
                    Divider()
                }
                ForEach(GMInstrument.Family.allCases, id: \.self) { family in
                    Section(family.rawValue) {
                        ForEach(family.programs) { instrument in
                            Button {
                                Task {
                                    await viewModel.setStaffProgram(
                                        Int(instrument.program), for: address
                                    )
                                }
                            } label: {
                                Text(instrument.name)
                            }
                        }
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Text(GMInstrument.instrument(for: UInt8(clamping: program)).name)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .menuIndicator(.hidden)
        }
        .font(.caption)
        .padding(.top, 2)
        .padding(.bottom, 4)
    }

    @ViewBuilder
    func visibilityButton(address: StaffAddress) -> some View {
        let isVisible = !viewModel.preferences.hiddenStaves.contains(address)

        Button {
            Task { await viewModel.toggleStaff(address: address) }
        } label: {
            EyeIcon(isOpen: isVisible, lineWidth: 2)
                .foregroundStyle(Color.accentColor)
                .frame(width: 28, height: 24)
        }
        .contentShape(.rect)
        .animation(.spring(duration: 0.18), value: isVisible)
    }
}

private enum InspectorTab: Hashable {
    case playback
    case visual
}

#Preview {
    let score = Score(
        division: 480,
        parts: [
            Part(
                id: "P0",
                trackName: "Violin",
                instrument: Instrument(
                    id: "violin",
                    channels: [InstrumentChannel(program: 40)] // GM 40 = Violin
                ),
                staves: [Staff()]
            ),
            Part(
                id: "P1",
                trackName: "Piano",
                instrument: Instrument(
                    id: "piano",
                    channels: [InstrumentChannel(program: 0)] // GM 0 = Acoustic Grand Piano
                ),
                staves: [Staff(), Staff()]
            ),
        ],
        metaTags: [:]
    )
    let repo = PreviewFakeRepository()
    let vm = ReaderViewModel(
        scoreItem: PreviewFakeRepository.sampleItem,
        repository: repo,
        gateway: PreviewFakeGateway(score: score),
        scoresDirectory: URL(filePath: "/tmp")
    )
    Text("Contents")
        .task { await vm.load() }
        .sheet(isPresented: .constant(true)) {
            InspectorView(viewModel: vm, score: score)
                .presentationDetents([.medium, .large])
        }
}
