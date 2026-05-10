import SheetMusicAudio
import SwiftUI

/// Per-Part GM program override Menu shown in the Reader Inspector's Playback
/// tab header. Lives outside `InspectorScreen` so the screen file stays under
/// length limits — semantics match the prior inline `programPicker` exactly.
struct ProgramPicker: View {
    @Bindable var viewModel: ReaderViewModel
    let partIndex: Int

    var body: some View {
        let program = viewModel.effectiveProgram(forPartIndex: partIndex)
        let hasOverride = viewModel.hasProgramOverride(forPartIndex: partIndex)
        HStack(spacing: 6) {
            Image(systemName: "music.note.list")
                .foregroundStyle(.secondary)
            Menu {
                if hasOverride {
                    resetButton
                    Divider()
                }
                ForEach(GMInstrument.Family.allCases, id: \.self) { family in
                    Section(family.rawValue) {
                        ForEach(family.programs) { instrument in
                            Button {
                                Task {
                                    await viewModel.setPartProgram(
                                        Int(instrument.program), forPartIndex: partIndex
                                    )
                                }
                            } label: {
                                Text(instrument.name)
                            }
                        }
                    }
                }
            } label: {
                menuLabel(program: program)
            }
            .menuIndicator(.hidden)
        }
        .font(.caption)
        .padding(.top, 2)
        .padding(.bottom, 4)
    }

    @ViewBuilder
    private var resetButton: some View {
        Button {
            Task { await viewModel.clearPartProgramOverride(forPartIndex: partIndex) }
        } label: {
            Label {
                Text("reader.preferences.resetDefault", bundle: .module)
            } icon: {
                Image(systemName: "arrow.uturn.backward")
            }
        }
    }

    @ViewBuilder
    private func menuLabel(program: Int) -> some View {
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
}
