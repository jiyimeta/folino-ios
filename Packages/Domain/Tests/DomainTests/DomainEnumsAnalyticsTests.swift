@testable import Domain
import Testing

struct DomainEnumsAnalyticsTests {
    @Test func `score format wire values`() {
        #expect(ScoreFormat.mscx.analyticsValue == "mscx")
        #expect(ScoreFormat.mscz.analyticsValue == "mscz")
        #expect(ScoreFormat.musicXML.analyticsValue == "musicxml")
        #expect(ScoreFormat.mxl.analyticsValue == "mxl")
        #expect(ScoreFormat.midi.analyticsValue == "midi")
    }

    @Test func `sort wire values`() {
        #expect(ScoreItemSort.dateAddedDesc.analyticsValue == "date_added")
        #expect(ScoreItemSort.titleAsc.analyticsValue == "title")
        #expect(ScoreItemSort.composerAsc.analyticsValue == "composer")
        #expect(ScoreItemSort.lastOpenedDesc.analyticsValue == "last_opened")
    }

    @Test func `layout wire values`() {
        #expect(ReaderLayoutMode.vertical.analyticsValue == "vertical")
        #expect(ReaderLayoutMode.horizontal.analyticsValue == "horizontal")
        #expect(ReaderLayoutMode.page.analyticsValue == "page")
    }

    @Test func `repeat wire values`() {
        #expect(RepeatMode.off.analyticsValue == "off")
        #expect(RepeatMode.loopAll.analyticsValue == "loop_all")
        #expect(RepeatMode.abLoop.analyticsValue == "ab_loop")
    }
}
