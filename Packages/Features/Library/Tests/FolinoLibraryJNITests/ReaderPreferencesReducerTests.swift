import Domain
@testable import FolinoLibraryJNI
import Testing

struct ReaderPreferencesReducerTests {
    private func base() -> ReaderPreferences {
        ReaderPreferences(scoreItemID: ScoreItemID(), staffSize: 14, hiddenStaves: [])
    }

    @Test func `set master volume clamps through init`() {
        let p = ReaderPreferencesReducer.setMasterVolume(base(), 5.0) // above max 3.0
        #expect(p.masterVolume == 3.0)
    }

    @Test func `tempo zero sentinel means no override`() {
        var p = ReaderPreferencesReducer.setTempoMultiplier(base(), 0.0)
        #expect(p.tempoMultiplier == nil)
        p = ReaderPreferencesReducer.setTempoMultiplier(base(), 1.5)
        #expect(p.tempoMultiplier == 1.5)
    }

    @Test func `a 4 zero sentinel means inherit`() {
        var p = ReaderPreferencesReducer.setA4ReferenceHz(base(), 0.0)
        #expect(p.a4ReferenceHz == nil)
        p = ReaderPreferencesReducer.setA4ReferenceHz(base(), 432)
        #expect(p.a4ReferenceHz == 432)
    }

    @Test func `set staff program updates addressed entry only`() {
        let p = ReaderPreferencesReducer.setStaffProgram(base(), part: 0, staff: 1, program: 40)
        #expect(p.staffProgramOverrides[StaffAddress(partIndex: 0, staffIndexInPart: 1)] == 40)
    }

    @Test func `set staff volume updates addressed entry only`() {
        let p = ReaderPreferencesReducer.setStaffVolume(base(), part: 1, staff: 0, volume: 0.25)
        #expect(p.staffVolumeOverrides[StaffAddress(partIndex: 1, staffIndexInPart: 0)] == 0.25)
    }

    @Test func `set staff hidden toggles membership`() {
        let addr = StaffAddress(partIndex: 1, staffIndexInPart: 0)
        var p = ReaderPreferencesReducer.setStaffHidden(base(), part: 1, staff: 0, hidden: true)
        #expect(p.hiddenStaves.contains(addr))
        p = ReaderPreferencesReducer.setStaffHidden(p, part: 1, staff: 0, hidden: false)
        #expect(!p.hiddenStaves.contains(addr))
    }

    @Test func `set clef empty removes override`() {
        var p = ReaderPreferencesReducer.setClef(base(), part: 0, staff: 0, rawType: "F")
        #expect(p.staffClefOverrides[StaffAddress(partIndex: 0, staffIndexInPart: 0)] == "F")
        p = ReaderPreferencesReducer.setClef(p, part: 0, staff: 0, rawType: "")
        #expect(p.staffClefOverrides[StaffAddress(partIndex: 0, staffIndexInPart: 0)] == nil)
    }

    @Test func `transpose clamps to seven semitones`() {
        let p = ReaderPreferencesReducer.setTranspose(base(), 99)
        #expect(p.transposeSemitones == 7)
    }

    @Test func `set staff size clamps`() {
        let p = ReaderPreferencesReducer.setStaffSize(base(), 100)
        #expect(p.staffSize == ReaderPreferences.maxStaffSize)
    }

    @Test func `set honor layout breaks`() {
        let p = ReaderPreferencesReducer.setHonorLayoutBreaks(base(), false)
        #expect(p.honorLayoutBreaks == false)
    }

    @Test func `encode decode round trips`() {
        let p = ReaderPreferencesReducer.setMasterVolume(base(), 1.2)
        let json = ReaderPreferencesReducer.encode(p)
        #expect(!json.isEmpty)
        #expect(ReaderPreferencesReducer.decode(json) == p)
    }

    @Test func `decode empty returns nil`() {
        #expect(ReaderPreferencesReducer.decode("") == nil)
    }
}
