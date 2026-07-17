import SwiftUI

/// The regular-width (iPad) persistent Edit palette: a vertical Liquid Glass card docked to the trailing edge (spec
/// §5.5/§5.8). Top to bottom: the live selection readout, the shared `EditorContextOps` in a 3-column grid, the
/// `+3度` / `+8度` interval shortcuts, and the voice picker. Unlike the iPhone callout it is always visible while
/// editing — the readout shows a "tap a note" fallback when nothing is selected.
struct EditorPaletteView: View {
    let viewModel: EditorViewModel

    private static let columns = Array(repeating: GridItem(.flexible(), spacing: 6), count: 3)
    private static let cardWidth: CGFloat = 260

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            readout

            LazyVGrid(columns: Self.columns, spacing: 6) {
                EditorContextOps.buttons(viewModel: viewModel)
            }

            HStack(spacing: 6) {
                intervalButton(.third, label: "editor.palette.addThird")
                intervalButton(.octave, label: "editor.palette.addOctave")
            }

            Divider()

            VStack(alignment: .leading, spacing: 4) {
                Text("editor.voice.label", bundle: .module)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                EditorVoicePicker(viewModel: viewModel)
            }
        }
        .padding(14)
        .frame(width: Self.cardWidth)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 22))
        .shadow(color: .gray.opacity(0.3), radius: 10, y: 5)
    }

    private var readout: some View {
        Group {
            if let item = viewModel.selectedItem, let score = viewModel.score {
                Text(verbatim: NoteNameFormatter.readout(for: item, in: score))
            } else {
                Text("editor.palette.noSelection", bundle: .module)
            }
        }
        .font(.footnote.monospacedDigit())
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func intervalButton(_ interval: EditorInterval, label: LocalizedStringKey) -> some View {
        Button {
            viewModel.addIntervalNote(interval)
        } label: {
            Text(label, bundle: .module)
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .frame(maxWidth: .infinity, minHeight: 44)
        }
        .buttonStyle(PadKeyStyle())
    }
}
