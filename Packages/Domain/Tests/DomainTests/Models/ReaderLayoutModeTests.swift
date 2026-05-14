import Domain
import Testing

struct ReaderLayoutModeTests {
    @Test func `raw values are stable`() {
        // @AppStorage("readerLayoutMode") persists the rawValue; a
        // rename would silently drop user state on the next launch.
        #expect(ReaderLayoutMode.vertical.rawValue == "vertical")
        #expect(ReaderLayoutMode.horizontal.rawValue == "horizontal")
        #expect(ReaderLayoutMode.page.rawValue == "page")
    }

    @Test func `all cases survive rawValue round trip`() {
        for mode in ReaderLayoutMode.allCases {
            #expect(ReaderLayoutMode(rawValue: mode.rawValue) == mode)
        }
    }

    @Test func `all cases contains vertical horizontal page`() {
        #expect(ReaderLayoutMode.allCases == [.vertical, .horizontal, .page])
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
