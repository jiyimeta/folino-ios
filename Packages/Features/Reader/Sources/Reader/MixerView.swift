import SheetMusicAudio
import SheetMusicCore
import SwiftUI

struct MixerView: View {
    @Bindable var viewModel: ReaderViewModel
    let score: Score

    var body: some View {
        List {
            Section {
                Picker("Layout", selection: $viewModel.layoutMode) {
                    Text("Vertical").tag(ReaderViewModel.LayoutMode.vertical)
                    Text("Horizontal").tag(ReaderViewModel.LayoutMode.horizontal)
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            }
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
        .listStyle(.plain)
        .buttonStyle(.plain)
        .padding(.top, 16)
        .environment(\.defaultMinListRowHeight, 28)
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
            MixerView(viewModel: vm, score: score)
                .presentationDetents([.medium, .large])
        }
}
