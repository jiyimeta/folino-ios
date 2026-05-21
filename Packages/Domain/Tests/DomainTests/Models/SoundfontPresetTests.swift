import Domain
import Testing

struct SoundfontPresetTests {
    @Test func `lightweight preset describes the bundled asset`() {
        #expect(SoundfontPreset.lightweight.fileName == "GeneralUser-GS.sf2")
        #expect(SoundfontPreset.lightweight.sizeBytes == 31 * 1024 * 1024)
        #expect(SoundfontPreset.lightweight.isBundled == true)
    }

    @Test func `high-quality preset describes the downloadable asset`() {
        #expect(SoundfontPreset.highQuality.fileName == "MuseScore_General.sf2")
        #expect(SoundfontPreset.highQuality.sizeBytes == 206 * 1024 * 1024)
        #expect(SoundfontPreset.highQuality.isBundled == false)
    }

    @Test func `rawValues are stable`() {
        #expect(SoundfontPreset.lightweight.rawValue == "lightweight")
        #expect(SoundfontPreset.highQuality.rawValue == "highQuality")
    }
}
