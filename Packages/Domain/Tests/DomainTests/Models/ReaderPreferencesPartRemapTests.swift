@testable import Domain
import SheetMusicCore
import Testing

@Suite("ReaderPreferences part remapping")
struct ReaderPreferencesPartRemapTests {
    private func prefs() -> ReaderPreferences {
        ReaderPreferences(
            scoreItemID: ScoreItemID(),
            hiddenStaves: [
                StaffAddress(partIndex: 0, staffIndexInPart: 0),
                StaffAddress(partIndex: 1, staffIndexInPart: 1),
            ],
            authoredHiddenStaves: [StaffAddress(partIndex: 1, staffIndexInPart: 0)],
            stripProgramOverrides: [MixerStripID(partIndex: 1, instrumentOrdinal: 0): 40],
            stripVolumeOverrides: [MixerStripID(partIndex: 0, instrumentOrdinal: 0): 0.5],
            staffClefOverrides: [StaffAddress(partIndex: 1, staffIndexInPart: 0): "F"],
        )
    }

    @Test func `reorder remaps every keyed collection`() {
        let remapped = prefs().remappingParts([0: 1, 1: 0])
        #expect(remapped.hiddenStaves == [
            StaffAddress(partIndex: 1, staffIndexInPart: 0),
            StaffAddress(partIndex: 0, staffIndexInPart: 1),
        ])
        #expect(remapped.authoredHiddenStaves == [StaffAddress(partIndex: 0, staffIndexInPart: 0)])
        #expect(remapped.stripProgramOverrides == [MixerStripID(partIndex: 0, instrumentOrdinal: 0): 40])
        #expect(remapped.stripVolumeOverrides == [MixerStripID(partIndex: 1, instrumentOrdinal: 0): 0.5])
        #expect(remapped.staffClefOverrides == [StaffAddress(partIndex: 0, staffIndexInPart: 0): "F"])
    }

    @Test func `removal drops that part's rows`() {
        let remapped = prefs().remappingParts([0: 0, 1: nil])
        #expect(remapped.hiddenStaves == [StaffAddress(partIndex: 0, staffIndexInPart: 0)])
        #expect(remapped.stripProgramOverrides.isEmpty)
        #expect(remapped.staffClefOverrides.isEmpty)
        #expect(remapped.authoredHiddenStaves.isEmpty)
        // Part 0 survived, so its own strip volume rides through untouched.
        #expect(remapped.stripVolumeOverrides == [MixerStripID(partIndex: 0, instrumentOrdinal: 0): 0.5])
    }

    @Test func `an unmapped index is dropped`() {
        // An address whose partIndex the mapping doesn't know (corrupt row) is dropped, not passed through.
        let remapped = prefs().remappingParts([0: 0])
        #expect(!remapped.hiddenStaves.contains { $0.partIndex == 1 })
        #expect(remapped.stripProgramOverrides.isEmpty)
        #expect(remapped.staffClefOverrides.isEmpty)
    }

    @Test func `staff index within a part is preserved`() {
        // A piano's lower staff must stay the LOWER staff of whatever index the part lands on — part operations
        // move whole parts, they never re-shape what is inside one.
        let piano = ReaderPreferences(
            scoreItemID: ScoreItemID(),
            hiddenStaves: [StaffAddress(partIndex: 2, staffIndexInPart: 1)],
        )
        let remapped = piano.remappingParts([0: nil, 1: 0, 2: 1])
        #expect(remapped.hiddenStaves == [StaffAddress(partIndex: 1, staffIndexInPart: 1)])
    }

    @Test func `instrument ordinal within a strip is preserved`() {
        let prefs = ReaderPreferences(
            scoreItemID: ScoreItemID(),
            hiddenStaves: [],
            stripProgramOverrides: [MixerStripID(partIndex: 1, instrumentOrdinal: 2): 12],
        )
        let remapped = prefs.remappingParts([0: nil, 1: 0])
        #expect(remapped.stripProgramOverrides == [MixerStripID(partIndex: 0, instrumentOrdinal: 2): 12])
    }

    @Test func `non-part-indexed settings survive untouched`() {
        let prefs = ReaderPreferences(
            scoreItemID: ScoreItemID(),
            staffSize: 15,
            hiddenStaves: [StaffAddress(partIndex: 0, staffIndexInPart: 0)],
            tempoMultiplier: 1.5,
            honorLayoutBreaks: true,
            repeatMode: .abLoop,
            masterVolume: 2,
            transposeSemitones: 3,
            a4ReferenceHz: 442,
            hasSeededAuthoredVisibility: true,
        )
        let remapped = prefs.remappingParts([0: 1])
        #expect(remapped.id == prefs.id)
        #expect(remapped.scoreItemID == prefs.scoreItemID)
        #expect(remapped.staffSize == 15)
        #expect(remapped.tempoMultiplier == 1.5)
        #expect(remapped.honorLayoutBreaks == true)
        #expect(remapped.repeatMode == .abLoop)
        #expect(remapped.masterVolume == 2)
        #expect(remapped.transposeSemitones == 3)
        #expect(remapped.a4ReferenceHz == 442)
        #expect(remapped.hasSeededAuthoredVisibility == true)
    }

    @Test func `the memberwise initializer's filtering reapplies`() {
        // The rewrite goes back through `init`, so a clef rawType that is not canonical is dropped on the way
        // through rather than being carried into the migrated row.
        var prefs = ReaderPreferences(scoreItemID: ScoreItemID(), hiddenStaves: [])
        prefs.staffClefOverrides = [StaffAddress(partIndex: 0, staffIndexInPart: 0): "not-a-clef"]
        #expect(prefs.remappingParts([0: 1]).staffClefOverrides.isEmpty)
    }

    @Test func `an identity mapping changes nothing`() {
        let original = prefs()
        #expect(original.remappingParts([0: 0, 1: 1]) == original)
    }

    @Test func `an empty mapping drops every part-indexed row`() {
        let remapped = prefs().remappingParts([:])
        #expect(remapped.hiddenStaves.isEmpty)
        #expect(remapped.authoredHiddenStaves.isEmpty)
        #expect(remapped.stripProgramOverrides.isEmpty)
        #expect(remapped.stripVolumeOverrides.isEmpty)
        #expect(remapped.staffClefOverrides.isEmpty)
    }
}
