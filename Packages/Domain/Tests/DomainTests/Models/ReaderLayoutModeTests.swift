import Domain
import Testing

struct ReaderLayoutModeTests {
    @Test func `raw values are stable`() {
        #expect(ReaderLayoutMode.vertical.rawValue == "vertical")
        #expect(ReaderLayoutMode.horizontal.rawValue == "horizontal")
    }

    @Test func `all cases contains both`() {
        #expect(ReaderLayoutMode.allCases == [.vertical, .horizontal])
    }

    @Test func `metronome key matches legacy app storage`() {
        // The string literal is load-bearing: existing user state lives under
        // this key, so changing it would silently reset every install.
        #expect(ReaderGlobalSettingsKey.metronomeEnabled == "readerMetronomeEnabled")
    }

    @Test func `layout mode key is stable`() {
        #expect(ReaderGlobalSettingsKey.layoutMode == "readerLayoutMode")
    }

    @Test func `pip enabled key is stable`() {
        #expect(
            ReaderGlobalSettingsKey.pictureInPictureEnabled == "readerPictureInPictureEnabled",
        )
    }

    @Test func `collapse multi measure rests key is stable`() {
        #expect(
            ReaderGlobalSettingsKey.collapseMultiMeasureRests
                == "readerCollapseMultiMeasureRests",
        )
    }
}
