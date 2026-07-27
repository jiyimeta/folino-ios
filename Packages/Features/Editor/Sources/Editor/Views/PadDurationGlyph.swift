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

    /// The rest counterpart of `ordered`, same durations in the same order. The ⌫ key wears one of these: what that
    /// key does is turn a note into a rest, so it shows the rest it is about to leave behind rather than a generic
    /// backspace arrow.
    ///
    /// Whole and half take the LEGER-LINE variants (`restWholeLegerLine` / `restHalfLegerLine`) rather than the bare
    /// glyphs. The two rests are the same black rectangle and differ only by which side of a staff line they attach
    /// to — on a staff that line tells them apart, but on a bare key there is no staff, so the two keys were
    /// indistinguishable. These are the same glyphs MuseScore uses when the rest hangs off the staff and has to
    /// carry its own line: whole below the line, half above it.
    static let rests: [(duration: NoteDuration, glyph: String)] = [
        (.whole, "\u{E4F4}"), // restWholeLegerLine — hangs under its line
        (.half, "\u{E4F5}"), // restHalfLegerLine — sits on top of its line
        (.quarter, "\u{E4E5}"), // restQuarter
        (.eighth, "\u{E4E6}"), // rest8th
        (.sixteenth, "\u{E4E7}"), // rest16th
    ]

    /// The rest glyph for `duration`. Durations the pad has no key for still resolve (a score can already contain
    /// them, and selecting one arms it); anything that isn't a plain note value — a dotted or tuplet-scaled
    /// `.fraction`, which the armed duration never is, since it stores base and dots separately — falls back to the
    /// quarter rest rather than drawing nothing.
    static func rest(for duration: NoteDuration?) -> String {
        switch duration {
        case .whole, .measure: rests[0].glyph
        case .half: rests[1].glyph
        case .quarter, .none, .fraction: rests[2].glyph
        case .eighth: rests[3].glyph
        case .sixteenth: rests[4].glyph
        case .thirtySecond: "\u{E4E8}" // rest32nd
        case .sixtyFourth, .oneTwentyEighth, .twoFiftySixth: "\u{E4E9}" // rest64th
        }
    }

    /// The NOTE glyph for `duration` — `ordered`'s lookup counterpart to `rest(for:)`, for the callout's summary key.
    /// Falls back to the quarter note for anything the pad has no key for.
    static func note(for duration: NoteDuration?) -> String {
        guard let duration, let match = ordered.first(where: { $0.duration == duration }) else {
            return ordered[2].glyph // quarter
        }
        return match.glyph
    }

    /// A note value written as TEXT — "♩." and friends — for the callout's length readout.
    ///
    /// SMuFL has no precomposed dotted-note character, but it does have a second set of note glyphs meant exactly for
    /// this: the metronome-mark notes (`metNoteWhole` … `metNote16thUp`) and `metAugmentationDot`, the ones a tempo
    /// marking is typed with. Unlike the engraving glyphs in `ordered` — whose advance width is a notehead, because
    /// the layout engine positions everything itself — these carry real advances (0.33–0.53 em), so the dot that
    /// follows lands where the font says it should. Composing the engraving note with a dot in a `HStack` is what put
    /// the dot in the wrong place: nothing there knew where the stem ended.
    static func textNote(for duration: NoteDuration?, dots: Int) -> String {
        let note = switch duration {
        case .whole, .measure: "\u{ECA2}" // metNoteWhole
        case .half: "\u{ECA3}" // metNoteHalfUp
        case .eighth: "\u{ECA7}" // metNote8thUp
        case .sixteenth: "\u{ECA9}" // metNote16thUp
        default: "\u{ECA5}" // metNoteQuarterUp
        }
        return note + String(repeating: "\u{ECB7}", count: max(0, dots)) // metAugmentationDot
    }

    /// The augmentation dot, SMuFL `augmentationDot`. Bravura has one — but it is 0.1 em wide *by design* (a dot is
    /// 0.4 staff spaces, and an em is four of them), so at the 20 pt the note glyphs are drawn at it comes out about
    /// a point across: a speck, which is why the pad's dot key started life as a drawn `Circle`. Rendered at ten
    /// times the wanted diameter and trimmed back to the glyph's own band (`lineTrim`), it becomes usable — and it is
    /// then the same ink, from the same font and the same text rasteriser, as the note glyphs beside it.
    static let augmentationDot = "\u{E1E7}"

    /// The tie key's glyph. SMuFL has no tie of its own — engravers draw ties as curves, not characters — so this is
    /// `articLaissezVibrerAbove`, whose glyph IS a tie curve (a "let vibrate" mark is a tie with nothing on its far
    /// end). Drawn in the score's own font, it reads as the same stroke the engine draws between two noteheads.
    static let tie = "\u{E4BA}" // articLaissezVibrerAbove

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
        lineTrim(size: size, glyphs: ordered.map(\.glyph))
    }

    /// The same trim for an arbitrary glyph set — the rest keys and the tie key have their own extents, and trimming
    /// them by the note glyphs' band would clip them (a whole rest hangs below its own baseline where a stem rises
    /// above it).
    static func lineTrim(size: CGFloat, glyphs: [String]) -> LineTrim {
        let font = ctFont(size: size)
        // Fall back to no trim if the music font isn't registered in this process: the metrics below would then
        // describe the system font, and trimming by them would clip the glyphs instead of the padding.
        guard (CTFontCopyFamilyName(font) as String) == fontFamily else { return LineTrim(top: 0, bottom: 0) }
        let bounds = glyphs.compactMap { glyphBounds(of: $0, in: font) }
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
