import CoreText
import Domain
import SwiftUI

/// The duration-key glyphs for `EditorPadView`, extracted from the view so the font they render with can be pinned by
/// a test (`EditorPadGlyphTests`) instead of only by eye.
///
/// These are SMuFL codepoints drawn with **Bravura** — the same music font the score itself is engraved with. It is
/// bundled inside `SheetMusicLayoutApple` and registered process-wide at launch (`FolinoApp.init` →
/// `EdwinFontLoader.registerOnce()` → `SheetMusicLayoutApple.install`), so the pad can name the family without the
/// Editor package taking a dependency on it — the module-architecture carve-out for direct `swift-sheet-music` use
/// covers `SheetMusicUI`, not the layout backend. `EditorPadGlyphTests` pins the family name against
/// `BravuraFont.familyName` so the literal below can't drift.
///
/// The v1 stand-ins were Unicode's Musical Symbols block (U+1D15D…) drawn with the system font, and every one of them
/// rendered as a .notdef box on device: no iOS font covers that block. Worse, U+1D15E…U+1D164 are canonical
/// *decompositions* (notehead + combining stem + combining flag), so a single key drew two or three boxes and pushed
/// the row past the screen edge.
///
/// Accessibility labels deliberately stay in the view as `LocalizedStringKey` literals — `xcstringstool` only
/// extracts literals, so moving them to runtime strings here would drop them from `Localizable.xcstrings`.
enum PadDurationGlyph {
    /// Font family the keys render with. `nil` would mean "the system font".
    static let fontFamily: String? = "Bravura"

    /// The duration keys, longest first — the order they appear on the pad. SMuFL names in comments; each is the
    /// "note with upward stem" glyph, so they all align on their noteheads at the text baseline.
    ///
    /// Stops at the sixteenth: 32nds and 64ths cost two keys out of a row that has to share a phone's width with the
    /// tuplet, tie and delete keys, and they're rare enough in the parts this edits that the trade isn't worth it.
    /// `NoteDuration` still models them, so a score that already contains them renders and edits fine.
    static let ordered: [(duration: NoteDuration, glyph: String)] = [
        (.whole, "\u{E1D2}"), // noteWhole
        (.half, "\u{E1D3}"), // noteHalfUp
        (.quarter, "\u{E1D5}"), // noteQuarterUp
        (.eighth, "\u{E1D7}"), // note8thUp
        (.sixteenth, "\u{E1D9}"), // note16thUp
    ]

    /// The CoreText font the keys are drawn with — the exact font `swiftUIFont(size:)` resolves to, so a test can ask
    /// it whether it actually has a glyph for each key.
    static func ctFont(size: CGFloat) -> CTFont {
        guard let fontFamily else {
            // `CTFontCreateUIFontForLanguage` is optional in Swift; fall back to a named font rather than force it.
            return CTFontCreateUIFontForLanguage(.system, size, nil)
                ?? CTFontCreateWithName("Helvetica" as CFString, size, nil)
        }
        return CTFontCreateWithName(fontFamily as CFString, size, nil)
    }

    static func swiftUIFont(size: CGFloat) -> Font {
        guard let fontFamily else { return .system(size: size) }
        return .custom(fontFamily, size: size)
    }

    /// How much empty line box to cut off a duration `Text`, in points.
    struct LineTrim: Equatable {
        var top: CGFloat
        var bottom: CGFloat
    }

    /// A music font reserves room for far more than a notehead — Bravura's ascent and descent are each ~2 em, so at
    /// 20 pt a duration key's `Text` claims ~80 pt of height to draw a glyph 5–27 pt tall, nearly all of it empty
    /// space below the note. Trimming with these insets (as negative padding) shrinks the label to the glyphs' own
    /// band.
    ///
    /// The trim is the SAME for every key — computed from the union of all seven glyph bounds, not each glyph's own —
    /// so all seven keep a common baseline and their noteheads stay on one line, the way a note-value palette reads.
    static func lineTrim(size: CGFloat) -> LineTrim {
        let font = ctFont(size: size)
        // Fall back to no trim if the music font isn't registered in this process: the metrics below would then
        // describe the system font, and trimming by them would clip the glyphs instead of the padding.
        guard (CTFontCopyFamilyName(font) as String) == fontFamily else { return LineTrim(top: 0, bottom: 0) }
        let bounds = ordered.compactMap { glyphBounds(of: $0.glyph, in: font) }
        guard let highest = bounds.map(\.maxY).max(), let lowest = bounds.map(\.minY).min() else {
            return LineTrim(top: 0, bottom: 0)
        }
        // SwiftUI lays a single line out as ascent + descent, with the baseline `ascent` below the top. Glyph extents
        // are measured up from that baseline, so the empty band above is `ascent - highest` and the one below is
        // `descent + lowest` (`lowest` is negative for anything dipping below the baseline).
        return LineTrim(
            top: max(0, CTFontGetAscent(font) - highest),
            bottom: max(0, CTFontGetDescent(font) + lowest),
        )
    }

    /// Typographic bounding box of `glyph`, in points, relative to the text baseline (y up). `nil` if the font has no
    /// glyph for it — `EditorPadGlyphTests` is what keeps that from happening silently.
    static func glyphBounds(of glyph: String, in font: CTFont) -> CGRect? {
        var utf16 = Array(glyph.utf16)
        var glyphs = [CGGlyph](repeating: 0, count: utf16.count)
        guard CTFontGetGlyphsForCharacters(font, &utf16, &glyphs, utf16.count), let first = glyphs.first, first != 0
        else { return nil }
        var rects = [CGRect](repeating: .zero, count: 1)
        var one = [first]
        _ = CTFontGetBoundingRectsForGlyphs(font, .default, &one, &rects, 1)
        return rects[0]
    }
}
