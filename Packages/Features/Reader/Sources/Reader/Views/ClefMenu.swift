import Domain
import SheetMusicLayoutApple
import SheetMusicUI
import SwiftUI

/// Per-staff clef override picker shown on the Reader Inspector's Visual tab. The trigger button shows the current clef
/// glyph; tapping opens a popover with a grid of SMuFL clef tiles grouped by family (treble / bass / C). Modeled after
/// the swift-sheet-music macOS example's `ClefPopover`.
struct ClefMenu: View {
    let layoutModel: LayoutSettingsModel
    let address: StaffAddress
    @State private var isPresented = false

    var body: some View {
        let effective = layoutModel.effectiveClef(for: address)
        let hasOverride = layoutModel.hasClefOverride(for: address)
        let canReset = layoutModel.isClefOverrideEffective(for: address)
        // Touch BravuraFont.register so previews and first-render paths get the SMuFL font even when the score view
        // hasn't been resolved yet.
        _ = BravuraFont.register
        return Button {
            isPresented = true
        } label: {
            triggerLabel(rawType: effective, hasOverride: hasOverride)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("reader.preferences.clef", bundle: .module))
        .popover(isPresented: $isPresented) {
            ClefPopoverContent(
                currentRawType: effective,
                canReset: canReset,
                onSelect: { choice in
                    Task { await layoutModel.setClefOverride(choice.rawType, for: address) }
                    isPresented = false
                },
                onReset: {
                    Task { await layoutModel.clearClefOverride(for: address) }
                    isPresented = false
                },
            )
            .presentationCompactAdaptation(.popover)
        }
    }

    private func triggerLabel(rawType: String, hasOverride: Bool) -> some View {
        HStack(spacing: 4) {
            triggerGlyph(rawType: rawType, hasOverride: hasOverride)
            Image(systemName: "chevron.up.chevron.down")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 4)
    }

    @ViewBuilder
    private func triggerGlyph(rawType: String, hasOverride: Bool) -> some View {
        let tint: Color = hasOverride ? .accentColor : .primary
        if let choice = ClefMenuChoice.from(rawType: rawType) {
            ClefGlyphPreview(choice: choice)
                .foregroundStyle(tint)
                .frame(minWidth: 18, alignment: .center)
        } else {
            Text(rawType)
                .font(.callout)
                .foregroundStyle(tint)
        }
    }
}

#if DEBUG
#Preview {
    @Previewable @State var viewModel = ReaderViewModel(
        scoreItem: PreviewFakeRepository.sampleItem,
        repository: PreviewFakeRepository(),
        gateway: PreviewFakeGateway(),
        scoresDirectory: URL(filePath: "/dev/null"),
    )
    ClefMenu(
        layoutModel: viewModel.layoutModel,
        address: StaffAddress(partIndex: 1, staffIndexInPart: 1),
    )
}
#endif
