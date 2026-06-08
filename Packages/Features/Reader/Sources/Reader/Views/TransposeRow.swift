import SwiftUI

struct TransposeRow: View {
    @Bindable var transposeModel: TransposeModel

    var body: some View {
        let binding = Binding<Int>(
            get: { transposeModel.semitones },
            set: { newValue in Task { await transposeModel.setSemitones(newValue) } },
        )
        HStack(spacing: 8) {
            Image(systemName: "arrow.up.arrow.down")
                .foregroundStyle(Color.accentColor)
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
