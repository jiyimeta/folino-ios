import Domain
import SwiftUI

struct ABPill: View {
    @Bindable var viewModel: ReaderViewModel

    var body: some View {
        HStack(spacing: 0) {
            endpointButton(
                label: "A",
                measureIndex: viewModel.pendingRepeatA?.measureIndex,
                onSet: { Task { await viewModel.setRepeatA() } },
                onClear: { Task { await viewModel.clearRepeatA() } }
            )
            Divider().frame(height: 24)
            endpointButton(
                label: "B",
                measureIndex: viewModel.pendingRepeatB?.measureIndex,
                onSet: { Task { await viewModel.setRepeatB() } },
                onClear: { Task { await viewModel.clearRepeatB() } }
            )
        }
        .background(.ultraThinMaterial, in: Capsule())
        .accessibilityElement(children: .contain)
        .accessibilityLabel("A–B repeat markers")
    }

    @ViewBuilder
    private func endpointButton(
        label: String,
        measureIndex: Int?,
        onSet: @escaping () -> Void,
        onClear: @escaping () -> Void
    ) -> some View {
        Button(action: onSet) {
            VStack(spacing: 0) {
                Text(label)
                    .font(.callout.bold())
                    .foregroundStyle(measureIndex == nil ? Color.secondary : Color.accentColor)
                Text(measureIndex.map { "m. \($0 + 1)" } ?? " ")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .frame(minWidth: 44)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .accessibilityLabel(label)
        .accessibilityValue(
            measureIndex.map { "Set to measure \($0 + 1)" } ?? "Not set"
        )
        .simultaneousGesture(
            LongPressGesture(minimumDuration: 0.4).onEnded { _ in onClear() }
        )
    }
}
