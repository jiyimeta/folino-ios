import Domain
import Foundation

/// The pad's SMuFL codepoints, and the one composition rule that goes with them.
///
/// These are drawn with **Bravura**, the same music font the score itself is engraved with — Compose renders the same
/// face from the same numbers, which is why the tables live here rather than beside the CoreText metrics pass that
/// trims them (`PadDurationGlyph`, Apple-only).
///
/// The v1 stand-ins were Unicode's Musical Symbols block (U+1D15D…) drawn with the system font, and every one of them
/// rendered as a .notdef box on device: no iOS font covers that block. Worse, U+1D15E…U+1D164 are canonical
/// *decompositions* (notehead + combining stem + combining flag), so a single key drew two or three boxes and pushed
/// the row past the screen edge. Whichever platform renders these, that is the failure mode to watch for.
public enum PadGlyphs {
    /// Font family the keys render with. `nil` would mean "the system font".
    public static let fontFamily: String? = "Bravura"

    /// The duration keys, longest first — the order they appear on the pad. SMuFL names in comments; each is the
    /// "note with upward stem" glyph, so they all align on their noteheads at the text baseline.
    ///
    /// Stops at the sixteenth: 32nds and 64ths cost two keys out of a row that has to share a phone's width with the
    /// tuplet, tie and delete keys, and they're rare enough in the parts this edits that the trade isn't worth it.
    /// `NoteDuration` still models them, so a score that already contains them renders and edits fine.
    public static let ordered: [(duration: NoteDuration, glyph: String)] = [
        (.whole, "\u{E1D2}"), // noteWhole
        (.half, "\u{E1D3}"), // noteHalfUp
        (.quarter, "\u{E1D5}"), // noteQuarterUp
        (.eighth, "\u{E1D7}"), // note8thUp
        (.sixteenth, "\u{E1D9}"), // note16thUp
    ]

    /// The rest counterpart of `ordered`, same durations in the same order. The rest key wears one of these: what that
    /// key does is turn a note into a rest, so it shows the rest it is about to leave behind rather than a generic
    /// backspace arrow.
    ///
    /// Whole and half take the LEGER-LINE variants (`restWholeLegerLine` / `restHalfLegerLine`) rather than the bare
    /// glyphs. The two rests are the same black rectangle and differ only by which side of a staff line they attach
    /// to — on a staff that line tells them apart, but on a bare key there is no staff, so the two keys were
    /// indistinguishable. These are the same glyphs MuseScore uses when the rest hangs off the staff and has to
    /// carry its own line: whole below the line, half above it.
    public static let rests: [(duration: NoteDuration, glyph: String)] = [
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
    public static func rest(for duration: NoteDuration?) -> String {
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
    public static func note(for duration: NoteDuration?) -> String {
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
    /// follows lands where the font says it should. Composing the engraving note with a dot in a stack is what put
    /// the dot in the wrong place: nothing there knew where the stem ended.
    public static func textNote(for duration: NoteDuration?, dots: Int) -> String {
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
    /// a point across: a speck, which is why the pad's dot key started life as a drawn circle. It has to be rendered
    /// at roughly ten times the wanted diameter and trimmed back to the glyph's own band to be usable — and it is
    /// then the same ink, from the same font and the same text rasteriser, as the note glyphs beside it.
    public static let augmentationDot = "\u{E1E7}"

    /// The tie key's glyph. SMuFL has no tie of its own — engravers draw ties as curves, not characters — so this is
    /// `articLaissezVibrerAbove`, whose glyph IS a tie curve (a "let vibrate" mark is a tie with nothing on its far
    /// end). Drawn in the score's own font, it reads as the same stroke the engine draws between two noteheads.
    public static let tie = "\u{E4BA}" // articLaissezVibrerAbove
}
