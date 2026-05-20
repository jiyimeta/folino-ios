import Domain
import Testing

struct SoundfontPresetTests {
    @Test func `bundled file name matches the asset committed under App resources`() {
        #expect(SoundfontPreset.generalUserGS.fileName == "GeneralUser-GS.sf2")
        #expect(SoundfontPreset.generalUserGS.sizeBytes == 31 * 1024 * 1024)
        #expect(SoundfontPreset.generalUserGS.isBundled == true)
    }

    @Test func `downloadable file name matches the GitHub release asset`() {
        #expect(SoundfontPreset.museScoreGeneral.fileName == "MuseScore_General.sf2")
        #expect(SoundfontPreset.museScoreGeneral.sizeBytes == 206 * 1024 * 1024)
        #expect(SoundfontPreset.museScoreGeneral.isBundled == false)
    }

    @Test func `rawValues are stable`() {
        #expect(SoundfontPreset.generalUserGS.rawValue == "generalUserGS")
        #expect(SoundfontPreset.museScoreGeneral.rawValue == "museScoreGeneral")
    }
}
