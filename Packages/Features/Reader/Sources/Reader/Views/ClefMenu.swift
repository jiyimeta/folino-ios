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

    @ViewBuilder
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
            Text(String(choice.smuflGlyph))
                .font(.custom(BravuraFont.familyName, fixedSize: 22))
                .foregroundStyle(tint)
                .frame(minWidth: 18, alignment: .center)
        } else {
            Text(rawType)
                .font(.callout)
                .foregroundStyle(tint)
        }
    }

    @ViewBuilder
    private func popoverContent(currentRawType: String, hasOverride: Bool) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if hasOverride { resetButton }
            tileRow(ClefMenuChoice.trebleFamily, current: currentRawType)
            Divider()
            tileRow(ClefMenuChoice.bassFamily, current: currentRawType)
            Divider()
            tileRow(ClefMenuChoice.cFamily, current: currentRawType)
        }
        .padding(20)
        // Cap the popover width so the 5-tile treble row scrolls
        // horizontally, giving the surrounding padding room to breathe
        // on small devices.
        .frame(width: 280)
    }

    @ViewBuilder
    private var resetButton: some View {
        Button {
            Task { await viewModel.clearClefOverride(for: address) }
            isPresented = false
        } label: {
            Label {
                Text("reader.preferences.clef.resetDefault", bundle: .module)
            } icon: {
                Image(systemName: "arrow.uturn.backward")
            }
            .font(.callout)
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func tileRow(_ choices: [ClefMenuChoice], current: String) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(choices, id: \.self) { choice in
                    tile(choice, current: current)
                }
            }
        }
    }

    @ViewBuilder
    private func tile(_ choice: ClefMenuChoice, current: String) -> some View {
        let isCurrent = choice.rawType == current
        Button {
            Task { await viewModel.setClefOverride(choice.rawType, for: address) }
            isPresented = false
        } label: {
            Canvas { ctx, size in
                drawTile(ctx: ctx, size: size, choice: choice)
            }
            .frame(width: 56, height: 60)
            .background(
                isCurrent
                    ? Color.accentColor.opacity(0.18)
                    : Color.clear
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(
                        isCurrent ? Color.accentColor : Color.gray.opacity(0.3),
                        lineWidth: isCurrent ? 2 : 1
                    )
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(choice.displayLabel, bundle: .module))
    }

    private func drawTile(
        ctx: GraphicsContext,
        size: CGSize,
        choice: ClefMenuChoice
    ) {
        let sp: CGFloat = 4
        let staffHeight = sp * 4 // 5 lines = 4 spaces
        let staffTop = (size.height - staffHeight) / 2
        let leftPad: CGFloat = 6
        let rightPad: CGFloat = 6
        for index in 0 ..< 5 {
            let y = staffTop + sp * CGFloat(index)
            var path = Path()
            path.move(to: CGPoint(x: leftPad, y: y))
            path.addLine(to: CGPoint(x: size.width - rightPad, y: y))
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
        }
        let glyphText = Text(String(choice.smuflGlyph))
            .font(.custom(BravuraFont.familyName, fixedSize: sp * 4))
            .foregroundColor(.primary)
        ctx.draw(
            ctx.resolve(glyphText),
            at: CGPoint(x: size.width / 2, y: middleY + yOffset),
            anchor: .center
        )
    }
}
