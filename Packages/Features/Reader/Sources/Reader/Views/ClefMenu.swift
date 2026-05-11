import Domain
import SheetMusicUI
import SwiftUI

/// Per-staff clef override picker shown on the Reader Inspector's Visual
/// tab. The trigger button shows the current clef glyph; tapping opens a
/// popover with a grid of SMuFL clef tiles grouped by family
/// (treble / bass / C). Modeled after the swift-sheet-music macOS
/// example's `ClefPopover`.
struct ClefMenu: View {
    @Bindable var viewModel: ReaderViewModel
    let address: StaffAddress
    @State private var isPresented = false

    var body: some View {
        let effective = viewModel.effectiveClef(for: address)
        let hasOverride = viewModel.hasClefOverride(for: address)
        // Touch BravuraFont.register so previews and first-render paths
        // get the SMuFL font even when the score view hasn't been
        // resolved yet.
        _ = BravuraFont.register
        return Button {
            isPresented = true
        } label: {
            triggerLabel(rawType: effective, hasOverride: hasOverride)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("reader.preferences.clef", bundle: .module))
        .popover(isPresented: $isPresented) {
            popoverContent(currentRawType: effective, hasOverride: hasOverride)
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
            clefPreview(choice: choice)
                .foregroundStyle(tint)
                .frame(minWidth: 18, alignment: .center)
        } else {
            Text(rawType)
                .font(.callout)
                .foregroundStyle(tint)
        }
    }

    private func popoverContent(currentRawType: String, hasOverride: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            // Percussion staves stay on percussion clefs; pitched staves
            // stay on pitched clefs. Mixing the two would produce
            // nonsensical engraving (a kick drum line under a treble G,
            // or a melody under `||`), so the picker hides the family
            // the staff doesn't belong to.
            if isPercussionStaff(rawType: currentRawType) {
                tileRow(ClefMenuChoice.percussionFamily, current: currentRawType)
            } else {
                tileRow(ClefMenuChoice.trebleFamily, current: currentRawType)
                Divider()
                tileRow(ClefMenuChoice.bassFamily, current: currentRawType)
                Divider()
                tileRow(ClefMenuChoice.cFamily, current: currentRawType)
            }
            if hasOverride {
                Divider()
                resetButton
                    .padding(.horizontal, 16)
            }
        }
        .padding(.vertical, 16)
        // Cap the popover width so the 5-tile treble row scrolls
        // horizontally, giving the surrounding padding room to breathe
        // on small devices.
        .frame(width: 260)
    }

    private func isPercussionStaff(rawType: String) -> Bool {
        ClefMenuChoice.from(rawType: rawType)?.isPercussion ?? false
    }

    private var resetButton: some View {
        Button {
            Task { await viewModel.clearClefOverride(for: address) }
            isPresented = false
        } label: {
            Text("reader.preferences.clef.resetDefault", bundle: .module)
                .font(.callout)
                .foregroundStyle(.tint)
        }
    }

    private func tileRow(_ choices: [ClefMenuChoice], current: String) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(choices, id: \.self) { choice in
                    tile(choice, current: current)
                }
            }
            .padding(.horizontal, 16)
        }
    }

    @ViewBuilder
    private func tile(_ choice: ClefMenuChoice, current: String) -> some View {
        let isCurrent = choice.rawType == current
        Button {
            Task { await viewModel.setClefOverride(choice.rawType, for: address) }
            isPresented = false
        } label: {
            clefPreview(choice: choice)
                .padding(.horizontal, 4)
                .padding(.vertical, 8)
                .background(
                    isCurrent
                        ? Color.accentColor.opacity(0.18)
                        : Color.clear,
                )
                .clipShape(.rect(cornerRadius: 6))
                .overlay(
                    // strokeBorder (vs stroke) keeps the line entirely inside
                    // the tile so the 1pt edge stays pixel-aligned instead of
                    // straddling the frame boundary at half-pixel offsets.
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(
                            isCurrent ? Color.accentColor : Color.gray.opacity(0.3),
                            lineWidth: isCurrent ? 2 : 1,
                        ),
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(choice.displayLabel, bundle: .module))
    }

    private func clefPreview(choice: ClefMenuChoice) -> some View {
        Canvas { ctx, size in
            drawTile(ctx: ctx, size: size, choice: choice)
        }
        .frame(width: 40, height: 52)
        .padding(.vertical, -8)
    }

    private func drawTile(
        ctx: GraphicsContext,
        size: CGSize,
        choice: ClefMenuChoice,
    ) {
        let sp: CGFloat = 4
        let staffHeight = sp * 4 // 5 lines = 4 spaces
        let staffTop = (size.height - staffHeight) / 2
        for index in 0 ..< 5 {
            let y = staffTop + sp * CGFloat(index)
            var path = Path()
            path.move(to: CGPoint(x: 0, y: y))
            path.addLine(to: CGPoint(x: size.width, y: y))
            ctx.stroke(path, with: .color(.primary.opacity(0.6)), lineWidth: 0.5)
        }
        // Anchor convention: origin Y is the staff's middle line. Treble
        // is +sp (G line, line 2 from bottom), bass is -sp (F line, line
        // 4), Alto C is 0 (line 3, middle), Tenor C is -sp (line 4).
        // The Tenor anchor here intentionally diverges from upstream's
        // shared alto/tenor `yOffset = 0` so the picker tile shows the
        // musically-correct C-line for tenor — the score renderer's
        // tenor positioning is a separate upstream concern.
        let middleY = staffTop + sp * 2
        let yOffset: CGFloat = switch choice {
        case .trebleG, .trebleG8va, .trebleG8vb, .trebleG15ma, .trebleG15mb:
            sp
        case .bassF, .bassF8va, .bassF8vb:
            -sp
        case .altoC3:
            0
        case .tenorC4:
            -sp
        case .percussion, .percussion2:
            // Percussion clefs are vertically centred on the staff (line
            // 3) — same as upstream `ClefRenderer`'s `yOffset = 0`.
            0
        }
        let glyphText = Text(String(choice.smuflGlyph))
            .font(.custom(BravuraFont.familyName, fixedSize: sp * 4))
            .foregroundColor(.primary)
        ctx.draw(
            ctx.resolve(glyphText),
            at: CGPoint(x: size.width / 2, y: middleY + yOffset),
            anchor: .center,
        )
    }
}

#Preview {
    @Previewable @State var viewModel = ReaderViewModel(
        scoreItem: PreviewFakeRepository.sampleItem,
        repository: PreviewFakeRepository(),
        gateway: PreviewFakeGateway(),
        scoresDirectory: URL(filePath: "/dev/null"),
    )
    ClefMenu(
        viewModel: viewModel,
        address: StaffAddress(partIndex: 1, staffIndexInPart: 1),
    )
}
