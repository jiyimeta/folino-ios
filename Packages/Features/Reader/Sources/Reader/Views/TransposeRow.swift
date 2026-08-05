import SwiftUI

struct TransposeRow: View {
    @Bindable var transposeModel: TransposeModel
    /// The Playback inspector keeps a leading icon to match its other icon-led rows; the Visual inspector's rows have
    /// no leading icons, so it opts out here.
    var showsIcon = true

    var body: some View {
        let binding = Binding<Int>(
            get: { transposeModel.effectiveSemitones },
            set: { newValue in Task { await transposeModel.setSemitones(newValue) } },
        )
        // The row content lives in the Stepper's own label (rather than a sibling HStack with `.labelsHidden()`),
        // so the List renders it as a labeled form row — giving the `−`/`+` the light `tertiarySystemFill` that
        // matches the staff-size / tempo steppers. A bare `.labelsHidden()` Stepper renders as a standalone control
        // with a darker fill, which read as inconsistent next to the other rows.
        Stepper(value: binding, in: -7 ... 7) {
            HStack(spacing: 8) {
                if showsIcon {
                    Image("sharp.flat", bundle: .module)
                        .foregroundStyle(Color.accentColor)
                }
                Text("reader.inspector.transpose", bundle: .module)
                Spacer()
                Button {
                    Task { await transposeModel.reset() }
                } label: {
                    Text(
                        verbatim: transposeModel.effectiveSemitones > 0
                            ? "+\(transposeModel.effectiveSemitones)" : "\(transposeModel.effectiveSemitones)",
                    )
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.primary)
                    .frame(minWidth: 32, alignment: .trailing)
                }
            }
        }
    }
}
