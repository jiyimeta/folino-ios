import Domain
import SwiftUI

/// Per-staff clef override Menu shown on the Reader Inspector's Visual tab.
/// Lives outside `InspectorScreen` so the screen file stays under length
/// limits.
struct ClefMenu: View {
    @Bindable var viewModel: ReaderViewModel
    let address: StaffAddress

    var body: some View {
        let effective = viewModel.effectiveClef(for: address)
        let hasOverride = viewModel.hasClefOverride(for: address)
        Menu {
            menuContent(hasOverride: hasOverride)
        } label: {
            menuLabel(rawType: effective, hasOverride: hasOverride)
        }
        .menuIndicator(.hidden)
        .accessibilityLabel(Text("reader.preferences.clef", bundle: .module))
    }

    @ViewBuilder
    private func menuContent(hasOverride: Bool) -> some View {
        if hasOverride {
            resetButton
            Divider()
        }
        familyButtons(ClefMenuChoice.trebleFamily)
        Divider()
        familyButtons(ClefMenuChoice.bassFamily)
        Divider()
        familyButtons(ClefMenuChoice.cFamily)
    }

    @ViewBuilder
    private var resetButton: some View {
        Button {
            Task { await viewModel.clearClefOverride(for: address) }
        } label: {
            Label {
                Text("reader.preferences.clef.resetDefault", bundle: .module)
            } icon: {
                Image(systemName: "arrow.uturn.backward")
            }
        }
    }

    @ViewBuilder
    private func familyButtons(_ choices: [ClefMenuChoice]) -> some View {
        ForEach(choices, id: \.self) { choice in
            Button {
                Task {
                    await viewModel.setClefOverride(choice.rawType, for: address)
                }
            } label: {
                Text(choice.displayLabel, bundle: .module)
            }
        }
    }

    @ViewBuilder
    private func menuLabel(rawType: String, hasOverride: Bool) -> some View {
        HStack(spacing: 4) {
            labelText(rawType: rawType)
                .lineLimit(1)
                .foregroundStyle(hasOverride ? Color.accentColor : Color.primary)
            Image(systemName: "chevron.up.chevron.down")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .font(.callout)
        .padding(.horizontal, 4)
    }

    private func labelText(rawType: String) -> Text {
        if let choice = ClefMenuChoice.from(rawType: rawType) {
            Text(choice.displayLabel, bundle: .module)
        } else {
            Text(rawType)
        }
    }
}
