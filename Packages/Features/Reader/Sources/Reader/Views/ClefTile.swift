import SheetMusicLayoutApple
import SwiftUI

/// A single selectable clef tile in the `ClefPopoverContent` grid: a small SMuFL preview that highlights when it is the
/// staff's current clef. Takes only the `choice` it draws and the `current` raw type it compares against, reporting the
/// tap back through `onSelect` rather than mutating any model directly.
struct ClefTile: View {
    let choice: ClefMenuChoice
    let current: String
    let onSelect: (ClefMenuChoice) -> Void

    var body: some View {
        let isCurrent = choice.rawType == current
        Button {
            onSelect(choice)
        } label: {
            ClefGlyphPreview(choice: choice)
                .padding(.horizontal, 4)
                .padding(.vertical, 8)
                .background(
                    isCurrent
                        ? Color.accentColor.opacity(0.18)
                        : Color.clear,
                )
                .clipShape(.rect(cornerRadius: 6))
                .overlay {
                    // strokeBorder (vs stroke) keeps the line entirely inside the tile so the 1pt edge stays
                    // pixel-aligned instead of straddling the frame boundary at half-pixel offsets.
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(
                            isCurrent ? Color.accentColor : Color.gray.opacity(0.3),
                            lineWidth: isCurrent ? 2 : 1,
                        )
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(choice.displayLabel, bundle: .module))
    }
}

/// The bare SMuFL clef glyph drawn on a 5-line staff. Shared by `ClefTile` and `ClefMenu`'s trigger glyph so the
/// staff-relative anchoring lives in one place.
struct ClefGlyphPreview: View {
    let choice: ClefMenuChoice

    var body: some View {
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
        // Anchor convention: origin Y is the staff's middle line, with +Y meaning down (toward the bottom line).
        // Mirrors upstream `ClefRenderer`'s yOffset table exactly:
        //   * Treble family: +sp (G line, line 2 from bottom)
        //   * Bass   family: -sp (F line, line 4 from bottom)
        //   * Soprano C:    +2sp (line 1, bottom)
        //   * Alto    C:    0    (line 3, middle)
        //   * Tenor   C:    -sp  (line 4)
        //   * Baritone C:   -2sp (line 5, top)
        //   * Percussion:   0    (centred)
        let middleY = staffTop + sp * 2
        let yOffset: CGFloat = switch choice {
        case .trebleG, .trebleG8va, .trebleG8vb, .trebleG15ma, .trebleG15mb:
            sp
        case .bassF, .bassF8va, .bassF8vb:
            -sp
        case .sopranoC1:
            2 * sp
        case .altoC3:
            0
        case .tenorC4:
            -sp
        case .baritoneC5:
            -2 * sp
        case .percussion, .percussion2:
            0
        }
        let glyphText = Text(String(choice.smuflGlyph))
            .font(.custom(BravuraFont.familyName, fixedSize: sp * 4))
            .foregroundStyle(.primary)
        ctx.draw(
            ctx.resolve(glyphText),
            at: CGPoint(x: size.width / 2, y: middleY + yOffset),
            anchor: .center,
        )
    }
}
