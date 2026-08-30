@testable import ScoreUI
import Testing

/// The signature pickers' vocabulary, pinned. Both tables are engraving spellings rather than prose — they are
/// deliberately outside the localization catalog, so a test is the only thing that can notice one drifting.
@Suite("Signature pickers")
struct SignaturePickerTests {
    /// Circle of fifths, C-major center, sharps then flats — the order `KeySignaturePicker` offers, extended to
    /// ±7 (the wizard's old menu stopped at ±6).
    private static let expectedLabels: [(Int, String)] = [
        (0, "C / Am"),
        (1, "G / Em"),
        (2, "D / Bm"),
        (3, "A / F♯m"),
        (4, "E / C♯m"),
        (5, "B / G♯m"),
        (6, "F♯ / D♯m"),
        (7, "C♯ / A♯m"),
        (-1, "F / Dm"),
        (-2, "B♭ / Gm"),
        (-3, "E♭ / Cm"),
        (-4, "A♭ / Fm"),
        (-5, "D♭ / B♭m"),
        (-6, "G♭ / E♭m"),
        (-7, "C♭ / A♭m"),
    ]

    @Test func `every key signature has its note-name label`() {
        for (concertKey, expected) in Self.expectedLabels {
            #expect(KeySignatureLabel.label(for: concertKey) == expected, "concertKey \(concertKey)")
        }
    }

    /// The picker offers all fifteen keys, in the tabulated order.
    @Test func `the key picker offers fifteen keys in circle-of-fifths order`() {
        #expect(KeySignaturePicker.keys == Self.expectedLabels.map(\.0))
    }

    @Test func `the time picker offers the ten preset meters`() {
        let expected = [(4, 4), (3, 4), (2, 4), (6, 8), (12, 8), (2, 2), (5, 4), (7, 8), (9, 8), (3, 8)]
        #expect(TimeSignaturePicker.presets.count == expected.count)
        for pair in expected {
            #expect(
                TimeSignaturePicker.presets.contains { $0.0 == pair.0 && $0.1 == pair.1 },
                "missing preset \(pair.0)/\(pair.1)",
            )
        }
    }

    /// The free-form denominator walks a fixed set of note values rather than ±1 — 5/3 is not a time signature.
    @Test func `the denominator steps through note values`() {
        #expect(TimeSignaturePicker.denominators == [1, 2, 4, 8, 16, 32])
    }
}
