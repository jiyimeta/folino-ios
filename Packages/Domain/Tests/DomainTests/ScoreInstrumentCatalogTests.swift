import Domain
import Testing

@Suite("ScoreInstrument catalog")
struct ScoreInstrumentCatalogTests {
    @Test func `catalog is well formed`() {
        #expect(ScoreInstrument.all.count >= 20)
        #expect(Set(ScoreInstrument.all.map(\.id)).count == ScoreInstrument.all.count)
        for instrument in ScoreInstrument.all {
            #expect(!instrument.staves.isEmpty)
            #expect((0 ... 127).contains(instrument.gmProgram))
        }
    }

    /// Every entry needs a staff abbreviation, not just a name: the layout engine labels systems 2+ with
    /// `shortName ?? ""`, so an entry without one engraves an unlabeled staff on every system after the first.
    @Test func `every entry carries a staff abbreviation`() {
        for instrument in ScoreInstrument.all {
            #expect(!instrument.englishAbbreviation.isEmpty, "\(instrument.id) has no abbreviation")
            #expect(instrument.partPlan().shortName == instrument.englishAbbreviation)
        }
    }

    @Test func `transposing entries carry the right intervals`() {
        #expect(ScoreInstrument.instrument(id: "clarinet-bb").map {
            ($0.transposeDiatonic, $0.transposeChromatic) == (-1, -2)
        } == true)
        #expect(ScoreInstrument.instrument(id: "horn-f").map {
            ($0.transposeDiatonic, $0.transposeChromatic) == (-4, -7)
        } == true)
        // Tenor voice and guitar carry the octave in the CLEF, not in a transposition.
        #expect(ScoreInstrument.instrument(id: "voice-tenor").map {
            $0.transposeChromatic == 0 && $0.staves.first?.clefType == "G8vb"
        } == true)
        #expect(ScoreInstrument.instrument(id: "guitar").map {
            $0.transposeChromatic == 0 && $0.staves.first?.clefType == "G8vb"
        } == true)
    }

    /// `StaffPlan.isPercussion` does not imply a clef: the ssm factory copies `clefType` through verbatim, so a
    /// drum part that only set the flag would engrave a treble clef over a percussion staff.
    @Test func `the drum kit entry is both percussion and PERC-clefed`() {
        let drumset = ScoreInstrument.instrument(id: "drumset")

        #expect(drumset?.isDrums == true)
        #expect(drumset?.staves.first?.isPercussion == true)
        #expect(drumset?.staves.first?.clefType == "PERC")
    }

    @Test func `a part plan mirrors its catalog entry`() throws {
        let clarinet = try #require(ScoreInstrument.instrument(id: "clarinet-bb"))

        let plan = clarinet.partPlan()

        #expect(plan.instrumentID == "clarinet-bb")
        #expect(plan.longName == clarinet.englishName)
        #expect(plan.shortName == clarinet.englishAbbreviation)
        #expect(plan.staves == clarinet.staves)
        #expect(plan.transposeDiatonic == clarinet.transposeDiatonic)
        #expect(plan.transposeChromatic == clarinet.transposeChromatic)
        #expect(plan.gmProgram == clarinet.gmProgram)
        #expect(plan.isDrums == clarinet.isDrums)
    }

    @Test func `every family has at least one instrument`() {
        for family in ScoreInstrument.Family.allCases {
            #expect(ScoreInstrument.all.contains { $0.family == family })
        }
    }

    @Test func `templates resolve against the catalog`() {
        for template in ScoreCreationTemplate.all {
            for id in template.instrumentIDs {
                #expect(ScoreInstrument.instrument(id: id) != nil)
            }
        }
        #expect(ScoreCreationTemplate.all.map(\.id)
            == ["solo-piano", "voice-piano", "satb", "string-quartet"])
    }

    /// A bracket group indexes into the template's own parts; an out-of-bounds range would be silently dropped
    /// by `Score.blank(_:)` rather than trapping, so it has to be caught here.
    @Test func `bracket groups stay inside the part list`() {
        for template in ScoreCreationTemplate.all {
            for group in template.bracketGroups {
                #expect(group.lowerBound >= 0)
                #expect(group.upperBound <= template.instrumentIDs.count)
            }
        }
    }
}
