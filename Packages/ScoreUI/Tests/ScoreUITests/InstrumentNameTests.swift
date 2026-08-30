import Domain
@testable import ScoreUI
import Testing

/// These run in the test bundle's own language (`en` on a default simulator), so they assert the *presence* of a
/// catalog entry rather than a particular translation — the mistake adding an instrument to Domain invites is
/// forgetting its xcstrings row.
///
/// Coverage is checked through the raw resolver with a sentinel fallback, never through
/// `localizedInstrumentName`: that function's whole job is to answer a miss with `englishName`, so asking it
/// would report a healthy-looking name for an instrument the catalog does not contain.
@Suite("Localized instrument names")
struct InstrumentNameTests {
    private static let sentinel = "<no catalog entry>"

    @Test func `every catalog entry has a localized name`() {
        for instrument in ScoreInstrument.all {
            let key = "instrument.\(instrument.id)"
            #expect(localizedName(forKey: key, fallback: Self.sentinel) != Self.sentinel, "missing \(key)")
            #expect(!localizedInstrumentName(instrument).isEmpty)
        }
    }

    @Test func `every family has a localized name`() {
        for family in ScoreInstrument.Family.allCases {
            let key = "instrumentFamily.\(family.rawValue)"
            #expect(localizedName(forKey: key, fallback: Self.sentinel) != Self.sentinel, "missing \(key)")
            #expect(!localizedInstrumentFamilyName(family).isEmpty)
        }
    }

    /// Two instruments that read the same in a picker are indistinguishable, and a copy-pasted xcstrings entry is
    /// the way that happens.
    @Test func `catalog names are distinct`() {
        let names = ScoreInstrument.all.map(localizedInstrumentName)
        #expect(Set(names).count == names.count)
    }

    /// The fallback door: a key with no catalog entry hands back the English name it was given, never the raw key.
    /// Exercised through the internal resolver because `ScoreInstrument`'s init is Domain-internal — there is no
    /// way to build an off-catalog instrument from here.
    @Test func `an unknown key falls back to the given name`() {
        #expect(localizedName(forKey: "instrument.no-such-instrument", fallback: "Ondes Martenot") == "Ondes Martenot")
    }
}
