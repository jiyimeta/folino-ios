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
                        .padding(.bottom, -4)
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
        HStack(spacing: 12) {
            Slider(value: volumeBinding, in: 0 ... 1)
                .disabled(viewModel.mutedStaves.contains(address))
                .padding(.vertical, -8)

            Button {
                viewModel.toggleStaffMute(address: address)
            } label: {
                Image(systemName: speakerIconSystemName(for: address))
                    .font(viewModel.mutedStaves.contains(address) ? .title2 : .headline)
                    .foregroundStyle(Color.accentColor)
                    .frame(
                        width: 24,
                        height: 24,
                        alignment: viewModel.mutedStaves.contains(address) ? .center : .leading
                    )
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
                .frame(width: 28, height: 18)
        }
        .contentShape(.rect)
        .animation(.spring(duration: 0.18), value: isVisible)
    }

    private func speakerIconSystemName(for address: StaffAddress) -> String {
        if viewModel.mutedStaves.contains(address) {
            return "speaker.slash.fill"
        }

        let value = viewModel.volume(for: address)

        return if value < 0.01 {
            "speaker.fill"
        } else if value < 0.34 {
            "speaker.wave.1.fill"
        } else if value < 0.67 {
            "speaker.wave.2.fill"
        } else {
            "speaker.wave.3.fill"
        }
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
