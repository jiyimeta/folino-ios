import Domain
import SwiftUI

/// Per-staff clef override Menu shown on the Reader Inspector's Visual tab.
/// Lives outside `InspectorScreen` so the screen file stays under length
/// limits and the menu's three-section structure is easier to scan.
struct ClefMenu: View {
    @Bindable var viewModel: ReaderViewModel
    let address: StaffAddress

    var body: some View {
        let effective = viewModel.effectiveClef(for: address)
        let hasOverride = viewModel.hasClefOverride(for: address)
        let label = ClefMenuChoice.from(rawType: effective)?.displayLabel ?? effective
        Menu {
            menuContent(hasOverride: hasOverride)
        } label: {
            menuLabel(label: label, hasOverride: hasOverride)
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
        familySection(ClefMenuChoice.trebleFamily, headerKey: "reader.preferences.clef.section.treble")
        familySection(ClefMenuChoice.bassFamily, headerKey: "reader.preferences.clef.section.bass")
        familySection(ClefMenuChoice.cFamily, headerKey: "reader.preferences.clef.section.cClefs")
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
    private func familySection(
        _ choices: [ClefMenuChoice],
        headerKey: LocalizedStringKey
    ) -> some View {
        Section {
            ForEach(choices, id: \.self) { choice in
                Button(choice.displayLabel) {
                    Task {
                        await viewModel.setClefOverride(choice.rawType, for: address)
                    }
                }
            }
        } header: {
            Text(headerKey, bundle: .module)
        }
    }

    @ViewBuilder
    private func menuLabel(label: String, hasOverride: Bool) -> some View {
        HStack(spacing: 4) {
            Text(label)
                .lineLimit(1)
                .foregroundStyle(hasOverride ? Color.accentColor : Color.primary)
            Image(systemName: "chevron.up.chevron.down")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .font(.callout)
        .padding(.horizontal, 4)
    }
}
