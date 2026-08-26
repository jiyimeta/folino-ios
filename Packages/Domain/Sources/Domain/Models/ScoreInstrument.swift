import Foundation

/// One entry of the reduced instrument catalog a new score can be built from: how the instrument is engraved
/// (staves, clefs, written-to-sounding transposition) and how it is played back (GM program, drum kit).
///
/// Lives in Domain rather than in a Feature — the `GMDrumKit` precedent — so Android reads the SAME catalog
/// over JNI instead of carrying a second, drifting copy of the instrument list. `ScoreInstrument` is also the
/// only place the notation facts live: `BlankScoreTemplate` deliberately keeps no catalog of its own and takes
/// the instrument fields verbatim from whatever the host passes it.
///
/// `englishName` is a fallback and the source value for the localization catalogs; the display name a user
/// reads is resolved in the UI layers from the key `"instrument.<id>"`, and passed back down through
/// `partPlan().longName`.
///
/// Clefs and transposition intervals follow MuseScore's `instruments.xml`; programs are GM standard.
public struct ScoreInstrument: Sendable, Equatable, Identifiable {
    /// Picker grouping. Declaration order is the order the sections are offered in, and `all` is stored in the
    /// same order, so a picker can walk either one.
    public enum Family: String, CaseIterable, Sendable {
        case voices
        case keyboards
        case strings
        case woodwinds
        case brass
        case guitarAndBass
        case percussion

        public var instruments: [ScoreInstrument] {
            ScoreInstrument.all.filter { $0.family == self }
        }
    }

    /// Stable across releases and persisted into the score's `Instrument.id` — never renamed to follow a
    /// display-name change.
    public let id: String
    public let family: Family
    public let englishName: String
    /// The staff label from the second system on. Standard engraving abbreviations ("Vln.", "E. Pno.") —
    /// MuseScore's `instruments.xml` `shortName`s.
    ///
    /// Not optional, and not derivable: every part needs one, because the layout engine draws
    /// `part.instrument.shortName ?? ""` on systems 2+ (`LayoutEngine+SystemBuild`), so a part without one
    /// engraves an unlabeled staff rather than falling back to the long name.
    ///
    /// Unlike `englishName` this is NOT currently localized anywhere — the UI layers pass it through as-is,
    /// because a staff abbreviation is an engraving convention rather than prose. If that ever needs to change
    /// it wants its own catalog, not a reuse of `"instrument.<id>"`.
    public let englishAbbreviation: String
    public let staves: [BlankScoreTemplate.StaffPlan]
    /// Diatonic steps from written to sounding pitch (negative = sounds lower). Zero for the instruments that
    /// carry their octave in the clef instead — tenor voice, guitar.
    public let transposeDiatonic: Int
    /// Semitones from written to sounding pitch (negative = sounds lower).
    public let transposeChromatic: Int
    public let gmProgram: Int
    public let isDrums: Bool
    /// Amateur playable range hint (MIDI note numbers, concert pitch) — stored for future range warnings; no
    /// M2 UI reads it. `nil` where a range is meaningless (drum kit).
    public let amateurRange: ClosedRange<Int>?

    init(
        id: String,
        family: Family,
        englishName: String,
        englishAbbreviation: String,
        staves: [BlankScoreTemplate.StaffPlan],
        transposeDiatonic: Int = 0,
        transposeChromatic: Int = 0,
        gmProgram: Int,
        isDrums: Bool = false,
        amateurRange: ClosedRange<Int>? = nil,
    ) {
        self.id = id
        self.family = family
        self.englishName = englishName
        self.englishAbbreviation = englishAbbreviation
        self.staves = staves
        self.transposeDiatonic = transposeDiatonic
        self.transposeChromatic = transposeChromatic
        self.gmProgram = gmProgram
        self.isDrums = isDrums
        self.amateurRange = amateurRange
    }

    // MARK: - Staff shapes

    private static let treble = [BlankScoreTemplate.StaffPlan(clefType: "G")]
    private static let bass = [BlankScoreTemplate.StaffPlan(clefType: "F")]
    private static let alto = [BlankScoreTemplate.StaffPlan(clefType: "C3")]
    /// Treble clef sounding an octave below what is written — the notation tenor voices and guitar use instead
    /// of an octave transposition, which is why both carry `transposeChromatic == 0`.
    private static let trebleOttavaBassa = [BlankScoreTemplate.StaffPlan(clefType: "G8vb")]
    /// Two staves; `Part.init(blankPlan:id:measures:)` adds the brace itself for any multi-staff part.
    private static let grandStaff = [
        BlankScoreTemplate.StaffPlan(clefType: "G"),
        BlankScoreTemplate.StaffPlan(clefType: "F"),
    ]
    /// Both halves are load-bearing: `isPercussion` selects the unpitched staff type and drops the key
    /// signature, while the clef is copied through verbatim — a plan that set only the flag would engrave a
    /// treble clef over a drum staff.
    private static let percussionStaff = [BlankScoreTemplate.StaffPlan(clefType: "PERC", isPercussion: true)]

    // MARK: - Catalog

    public static let all: [ScoreInstrument] = [
        ScoreInstrument(
            id: "voice-soprano", family: .voices, englishName: "Soprano",
            englishAbbreviation: "S.",
            staves: treble, gmProgram: 52, amateurRange: 60 ... 81,
        ),
        ScoreInstrument(
            id: "voice-alto", family: .voices, englishName: "Alto",
            englishAbbreviation: "A.",
            staves: treble, gmProgram: 52, amateurRange: 53 ... 74,
        ),
        ScoreInstrument(
            id: "voice-tenor", family: .voices, englishName: "Tenor",
            englishAbbreviation: "T.",
            staves: trebleOttavaBassa, gmProgram: 52, amateurRange: 48 ... 69,
        ),
        ScoreInstrument(
            id: "voice-bass", family: .voices, englishName: "Bass",
            englishAbbreviation: "B.",
            staves: bass, gmProgram: 52, amateurRange: 41 ... 62,
        ),
        ScoreInstrument(
            id: "voice", family: .voices, englishName: "Voice",
            englishAbbreviation: "Vo.",
            staves: treble, gmProgram: 52, amateurRange: 48 ... 79,
        ),
        ScoreInstrument(
            id: "piano", family: .keyboards, englishName: "Piano",
            englishAbbreviation: "Pno.",
            staves: grandStaff, gmProgram: 0, amateurRange: 21 ... 108,
        ),
        ScoreInstrument(
            id: "electric-piano", family: .keyboards, englishName: "Electric Piano",
            englishAbbreviation: "E. Pno.",
            staves: grandStaff, gmProgram: 4, amateurRange: 21 ... 108,
        ),
        ScoreInstrument(
            id: "organ", family: .keyboards, englishName: "Organ",
            englishAbbreviation: "Org.",
            staves: grandStaff, gmProgram: 19, amateurRange: 36 ... 96,
        ),
        ScoreInstrument(
            id: "violin", family: .strings, englishName: "Violin",
            englishAbbreviation: "Vln.",
            staves: treble, gmProgram: 40, amateurRange: 55 ... 91,
        ),
        ScoreInstrument(
            id: "viola", family: .strings, englishName: "Viola",
            englishAbbreviation: "Vla.",
            staves: alto, gmProgram: 41, amateurRange: 48 ... 84,
        ),
        ScoreInstrument(
            id: "violoncello", family: .strings, englishName: "Cello",
            englishAbbreviation: "Vc.",
            staves: bass, gmProgram: 42, amateurRange: 36 ... 76,
        ),
        ScoreInstrument(
            id: "contrabass", family: .strings, englishName: "Contrabass",
            englishAbbreviation: "Cb.",
            staves: bass, transposeDiatonic: -7, transposeChromatic: -12,
            gmProgram: 43, amateurRange: 28 ... 62,
        ),
        ScoreInstrument(
            id: "flute", family: .woodwinds, englishName: "Flute",
            englishAbbreviation: "Fl.",
            staves: treble, gmProgram: 73, amateurRange: 60 ... 96,
        ),
        ScoreInstrument(
            id: "oboe", family: .woodwinds, englishName: "Oboe",
            englishAbbreviation: "Ob.",
            staves: treble, gmProgram: 68, amateurRange: 58 ... 87,
        ),
        ScoreInstrument(
            id: "clarinet-bb", family: .woodwinds, englishName: "Clarinet in B\u{266D}",
            englishAbbreviation: "Cl.",
            staves: treble, transposeDiatonic: -1, transposeChromatic: -2,
            gmProgram: 71, amateurRange: 50 ... 89,
        ),
        ScoreInstrument(
            id: "alto-sax-eb", family: .woodwinds, englishName: "Alto Saxophone",
            englishAbbreviation: "A. Sax.",
            staves: treble, transposeDiatonic: -5, transposeChromatic: -9,
            gmProgram: 65, amateurRange: 49 ... 80,
        ),
        ScoreInstrument(
            id: "tenor-sax-bb", family: .woodwinds, englishName: "Tenor Saxophone",
            englishAbbreviation: "T. Sax.",
            staves: treble, transposeDiatonic: -8, transposeChromatic: -14,
            gmProgram: 66, amateurRange: 44 ... 75,
        ),
        ScoreInstrument(
            id: "bassoon", family: .woodwinds, englishName: "Bassoon",
            englishAbbreviation: "Bsn.",
            staves: bass, gmProgram: 70, amateurRange: 34 ... 72,
        ),
        ScoreInstrument(
            id: "trumpet-bb", family: .brass, englishName: "Trumpet in B\u{266D}",
            englishAbbreviation: "Tpt.",
            staves: treble, transposeDiatonic: -1, transposeChromatic: -2,
            gmProgram: 56, amateurRange: 52 ... 82,
        ),
        ScoreInstrument(
            id: "horn-f", family: .brass, englishName: "Horn in F",
            englishAbbreviation: "Hn.",
            staves: treble, transposeDiatonic: -4, transposeChromatic: -7,
            gmProgram: 60, amateurRange: 34 ... 77,
        ),
        ScoreInstrument(
            id: "trombone", family: .brass, englishName: "Trombone",
            englishAbbreviation: "Tbn.",
            staves: bass, gmProgram: 57, amateurRange: 40 ... 72,
        ),
        ScoreInstrument(
            id: "tuba", family: .brass, englishName: "Tuba",
            englishAbbreviation: "Tba.",
            staves: bass, gmProgram: 58, amateurRange: 26 ... 58,
        ),
        ScoreInstrument(
            id: "guitar", family: .guitarAndBass, englishName: "Guitar",
            englishAbbreviation: "Gtr.",
            staves: trebleOttavaBassa, gmProgram: 25, amateurRange: 40 ... 83,
        ),
        ScoreInstrument(
            id: "bass-guitar", family: .guitarAndBass, englishName: "Bass Guitar",
            englishAbbreviation: "B. Gtr.",
            staves: bass, transposeDiatonic: -7, transposeChromatic: -12,
            gmProgram: 34, amateurRange: 28 ... 65,
        ),
        ScoreInstrument(
            id: "drumset", family: .percussion, englishName: "Drum Kit",
            englishAbbreviation: "Dr.",
            staves: percussionStaff, gmProgram: 0, isDrums: true,
        ),
    ]

    /// The catalog entry for a stored instrument id, or `nil` for an id this build does not know — a score
    /// imported from another program, or written by a later folino that added an instrument.
    public static func instrument(id: String) -> ScoreInstrument? {
        all.first { $0.id == id }
    }

    /// This instrument as a part of a new score. `longName`/`shortName` are the English name and abbreviation;
    /// UI layers that have a localization catalog overwrite them with the localized forms before handing the
    /// plan to `Score.blank(_:)`, so the part labels a user reads are in their language while the catalog stays
    /// Foundation-only.
    ///
    /// `shortName` is always set. The layout engine labels systems 2+ with `shortName ?? ""`, so leaving it nil
    /// would engrave an unlabeled staff on every system after the first.
    public func partPlan() -> BlankScoreTemplate.PartPlan {
        BlankScoreTemplate.PartPlan(
            instrumentID: id,
            longName: englishName,
            shortName: englishAbbreviation,
            staves: staves,
            transposeDiatonic: transposeDiatonic,
            transposeChromatic: transposeChromatic,
            gmProgram: gmProgram,
            isDrums: isDrums,
        )
    }
}
