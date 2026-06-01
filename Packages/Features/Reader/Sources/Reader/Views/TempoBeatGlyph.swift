import CoreText
import SheetMusicLayoutApple
import SwiftUI
import UIKit

/// Draws a tempo marking's beat note (a SMuFL "Individual notes" glyph string from `Tempo.beatGlyph`, e.g. a quarter
/// or a dotted quarter) sized to its own ink — not the Bravura font's line box, which is ~1 em tall and would leave the
/// surrounding row far taller than the glyph. The frame equals the glyph's image bounds, so the whole glyph (notehead
/// *and* stem) sits centered when placed in a `.center`-aligned `HStack` next to the "= 120" text.
struct TempoBeatGlyph: View {
    let glyph: String
    let color: Color
    /// `fontSize` scaled by the user's Dynamic Type setting, relative to `.callout` — the same text style the adjacent
    /// "= 120" value uses — so the glyph grows and shrinks in lockstep with it. The passed `fontSize` is the size at
    /// the default (Large) content size.
    @ScaledMetric private var fontSize: CGFloat

    init(glyph: String, fontSize: CGFloat, color: Color = .primary) {
        self.glyph = glyph
        self.color = color
        _fontSize = ScaledMetric(wrappedValue: fontSize, relativeTo: .callout)
    }

    var body: some View {
        let ink = Self.inkBounds(glyph: glyph, fontSize: fontSize)
        Canvas { context, size in
            context.withCGContext { cg in
                let font = CTFontCreateWithName(BravuraFont.familyName as CFString, fontSize, nil)
                let line = CTLineCreateWithAttributedString(NSAttributedString(
                    string: glyph,
                    attributes: [.font: font, .foregroundColor: UIColor(color)],
                ) as CFAttributedString)
                // CoreText draws baseline-up; flip into the Canvas's top-left space, then offset so the glyph's ink
                // rect maps exactly onto the canvas (which is sized to that ink), filling it with no slack.
                cg.textMatrix = .identity
                cg.translateBy(x: 0, y: size.height)
                cg.scaleBy(x: 1, y: -1)
                cg.textPosition = CGPoint(x: -ink.minX, y: -ink.minY)
                CTLineDraw(line, cg)
            }
        }
        .frame(width: ink.width, height: ink.height)
        .accessibilityHidden(true)
    }

    /// Image (ink) bounds of `glyph` rendered in Bravura at `fontSize`. Touches `BravuraFont.register` first so the
    /// family resolves instead of falling back to a system font that lacks the PUA glyphs.
    static func inkBounds(glyph: String, fontSize: CGFloat) -> CGRect {
        _ = BravuraFont.register
        let font = CTFontCreateWithName(BravuraFont.familyName as CFString, fontSize, nil)
        let line = CTLineCreateWithAttributedString(NSAttributedString(
            string: glyph, attributes: [.font: font],
        ) as CFAttributedString)
        let bounds = CTLineGetImageBounds(line, nil)
        guard !bounds.isNull, bounds.width > 0, bounds.height > 0 else {
            return CGRect(x: 0, y: 0, width: fontSize, height: fontSize)
        }
        return bounds
    }
}

#if DEBUG
#Preview("Tempo beat glyphs") {
    let cases: [(String, String)] = [
        ("quarter", "\u{E1D5}"),
        ("dotted quarter", "\u{E1D5}\u{E1E7}"),
        ("eighth", "\u{E1D7}"),
        ("dotted eighth", "\u{E1D7}\u{E1E7}"),
        ("half", "\u{E1D3}"),
    ]
    return VStack(alignment: .leading, spacing: 10) {
        ForEach(cases, id: \.0) { label, glyph in
            HStack(spacing: 4) {
                TempoBeatGlyph(glyph: glyph, fontSize: 18)
                Text(verbatim: "= 120")
                    .font(.callout.monospacedDigit())
                Text(label)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 12)
            }
        }
    }
    .padding(40)
}
#endif
