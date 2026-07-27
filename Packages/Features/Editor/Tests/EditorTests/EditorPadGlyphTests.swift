import CoreText
import Domain
@testable import Editor
import SheetMusicLayoutApple
import Testing

/// Pins the pad's duration glyphs to a font that actually has them.
///
/// The v1 stand-ins were Unicode Musical Symbols (U+1D15D…) drawn with the system font. No font on iOS covers that
/// block, so on device every duration key rendered as a .notdef box — and because U+1D15E…U+1D164 are canonical
/// *decompositions* (notehead + combining stem/flag), those keys drew two boxes each and shoved the row off-screen.
/// Nothing caught it: the glyphs are valid Swift strings, and the layout only breaks once a real font is consulted.
struct EditorPadGlyphTests {
    /// The pad names the family as a literal (the Editor package deliberately doesn't link the layout backend), so
    /// pin it against the real thing — a rename upstream would otherwise silently drop the pad back to tofu.
    @Test func `the pad's font family is the bundled music font`() {
        #expect(PadDurationGlyph.fontFamily == BravuraFont.familyName)
    }

    /// The regression test proper: ask the very font the pad renders with whether it can draw each key. Registration
    /// is what `SheetMusicLayoutApple.install` does at app launch; touch it here so the test process resolves the
    /// family the same way the app does.
    @Test func `every duration glyph resolves in the font the pad renders with`() {
        #expect(BravuraFont.register, "the bundled music font failed to register")
        let font = PadDurationGlyph.ctFont(size: 24)
        for entry in PadDurationGlyph.ordered {
            var utf16 = Array(entry.glyph.utf16)
            var glyphs = [CGGlyph](repeating: 0, count: utf16.count)
            let resolved = CTFontGetGlyphsForCharacters(font, &utf16, &glyphs, utf16.count)
            #expect(resolved, "\(entry.duration) has no glyph in \(PadDurationGlyph.fontFamily ?? "the system font")")
            #expect(glyphs.allSatisfy { $0 != 0 }, "\(entry.duration) resolved to .notdef")
        }
    }

    /// Each key must be ONE scalar: a decomposed sequence draws as two glyphs side by side, which is both wrong and
    /// twice as wide as the layout budgets for.
    @Test func `every duration glyph is a single Unicode scalar`() {
        for entry in PadDurationGlyph.ordered {
            #expect(
                entry.glyph.unicodeScalars.count == 1,
                "\(entry.duration) is \(entry.glyph.unicodeScalars.count) scalars, so it draws as that many glyphs",
            )
        }
    }

    @Test func `the pad offers each duration once, longest first`() {
        let durations = PadDurationGlyph.ordered.map(\.duration)
        #expect(durations == [.whole, .half, .quarter, .eighth, .sixteenth])
    }

    /// The trim has to leave exactly the glyphs' own band: too little and the key keeps the music font's ~2 em of
    /// empty space (the pad grew tall with a wide gap under every note); too much and it would clip the stems.
    @Test func `trimming the line box leaves exactly the glyph band`() throws {
        #expect(BravuraFont.register)
        let size: CGFloat = 20
        let font = PadDurationGlyph.ctFont(size: size)
        let bounds = PadDurationGlyph.ordered.compactMap { PadDurationGlyph.glyphBounds(of: $0.glyph, in: font) }
        #expect(bounds.count == PadDurationGlyph.ordered.count)

        let trim = PadDurationGlyph.lineTrim(size: size)
        let lineHeight = CTFontGetAscent(font) + CTFontGetDescent(font)
        let trimmed = lineHeight - trim.top - trim.bottom
        let highest = try #require(bounds.map(\.maxY).max())
        let lowest = try #require(bounds.map(\.minY).min())
        let glyphBand = highest - lowest
        #expect(abs(trimmed - glyphBand) < 0.01, "trimmed to \(trimmed) pt for a \(glyphBand) pt band of glyphs")
        // The key is 44 pt tall; a label taller than that would push the pad's rows apart.
        #expect(trimmed <= 44)
        #expect(lineHeight > 44, "no trim would be needed if the line box already fit")
    }

    /// Without the music font registered the metrics describe the system font, and trimming by them would clip the
    /// glyphs. Falling back to no trim keeps the pad merely roomy instead of broken.
    @Test func `no trim is applied when the music font is unavailable`() {
        let trim = PadDurationGlyph.lineTrim(size: 20)
        if PadDurationGlyph.fontFamily.map({ CTFontCopyFamilyName(PadDurationGlyph.ctFont(size: 20)) as String != $0 })
            ?? true
        {
            #expect(trim == PadDurationGlyph.LineTrim(top: 0, bottom: 0))
        }
    }

    /// Every key must be distinct — two durations sharing a glyph would be indistinguishable on the pad.
    @Test func `no two duration keys share a glyph`() {
        let glyphs = PadDurationGlyph.ordered.map(\.glyph)
        #expect(Set(glyphs).count == glyphs.count)
    }
}
