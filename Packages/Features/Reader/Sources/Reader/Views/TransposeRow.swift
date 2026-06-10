import SwiftUI

struct TransposeRow: View {
    @Bindable var transposeModel: TransposeModel
    /// The Playback inspector keeps a leading icon to match its other icon-led rows; the Visual inspector's rows have
    /// no leading icons, so it opts out here.
    var showsIcon = true

    var body: some View {
        let binding = Binding<Int>(
            get: { transposeModel.semitones },
            set: { newValue in Task { await transposeModel.setSemitones(newValue) } },
        )
        HStack(spacing: 8) {
            if showsIcon {
                Image(systemName: "arrow.up.arrow.down")
                    .foregroundStyle(Color.accentColor)
            }
            Text("reader.inspector.transpose", bundle: .module)
            Spacer()
            Button {
                Task { await transposeModel.reset() }
            } label: {
                Text(
                    verbatim: transposeModel.semitones > 0
                        ? "+\(transposeModel.semitones)" : "\(transposeModel.semitones)",
                )
                .font(.callout.monospacedDigit())
                .foregroundStyle(.primary)
                .frame(minWidth: 32, alignment: .trailing)
            }
            Stepper(value: binding, in: -7 ... 7) { EmptyView() }
                .labelsHidden()
                .fixedSize()
        }
    }
}
