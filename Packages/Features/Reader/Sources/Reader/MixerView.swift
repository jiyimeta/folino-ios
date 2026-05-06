import SheetMusicCore
import SwiftUI

struct MixerView: View {
    @Bindable var viewModel: ReaderViewModel
    let score: Score

    var body: some View {
        List {
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
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
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
                instrument: Instrument(id: "violin"),
                staves: [Staff()]
            ),
            Part(
                id: "P1",
                trackName: "Piano",
                instrument: Instrument(id: "piano"),
                staves: [Staff(), Staff()]
            ),
        ],
        metaTags: [:]
    )
    let repo = PreviewFakeRepository()
    let vm = ReaderViewModel(
        scoreItem: PreviewFakeRepository.sampleItem,
        repository: repo,
        gateway: PreviewFakeGateway(),
        scoresDirectory: URL(filePath: "/tmp")
    )
    Text("Contents")
        .sheet(isPresented: .constant(true)) {
            MixerView(viewModel: vm, score: score)
                .presentationDetents([.medium, .large])
        }
}
