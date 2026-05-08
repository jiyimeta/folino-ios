import Domain
import Testing

@Suite
struct ReaderLayoutModeTests {
    @Test func rawValuesAreStable() {
        #expect(ReaderLayoutMode.vertical.rawValue == "vertical")
        #expect(ReaderLayoutMode.horizontal.rawValue == "horizontal")
    }

    @Test func allCasesContainsBoth() {
        #expect(ReaderLayoutMode.allCases == [.vertical, .horizontal])
    }

    @Test func metronomeKeyMatchesLegacyAppStorage() {
        // The string literal is load-bearing: existing user state lives under
        // this key, so changing it would silently reset every install.
        #expect(ReaderGlobalSettingsKey.metronomeEnabled == "readerMetronomeEnabled")
    }

    @Test func layoutModeKeyIsStable() {
        #expect(ReaderGlobalSettingsKey.layoutMode == "readerLayoutMode")
    }
}
