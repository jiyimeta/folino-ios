import CoreGraphics
import Domain
import Foundation
@testable import Reader
import SheetMusicCore
import Testing

@MainActor
struct ReaderViewModelPDFPlaybackTests {
    private func makeVM(
        parser: (any PDFPlaybackParser)?,
        controller: FakePlaybackController? = nil,
    ) -> ReaderViewModel {
        ReaderViewModel(
            scoreItem: PreviewFakeRepository.sampleItem,
            repository: FakeScoreLibraryRepository(),
            gateway: FakeScoreFileGateway(),
            scoresDirectory: FileManager.default.temporaryDirectory,
            playbackController: controller,
            pdfPlaybackParser: parser,
        )
    }

    /// A minimal single-note score — just enough to count as playable. The default fixture for
    /// `sampleResult`, since a "successful parse" fixture should actually have something to play.
    private func playableScore() -> Score {
        let element = VoiceElement.chord(Chord(duration: .quarter, notes: [Note(pitch: 60, tpc: 14)]))
        let measure = Measure(voices: [Voice(elements: [element])])
        return Score(division: 480, parts: [
            Part(id: "P0", instrument: Instrument(id: "i"), staves: [Staff(measures: [measure])]),
        ])
    }

    private func sampleResult(
        score: Score? = nil,
        cursorRect: PDFCursorRect? = PDFCursorRect(pageIndex: 0, rect: CGRect(x: 10, y: 20, width: 4, height: 90)),
    ) -> PDFPlaybackParseResult {
        let score = score ?? playableScore()
        return PDFPlaybackParseResult(
            score: score,
            geometry: StubPDFPlaybackGeometry(
                pageSizes: [0: CGSize(width: 600, height: 800)],
                cursorRect: cursorRect,
                hitCursor: .beat(measureIndex: 2, tickInMeasure: 0),
            ),
            diagnostics: [],
        )
    }

    /// Two parts (1 + 2 staves) of four measures, each measure holding two quarter chords — enough for the mixer's
    /// flattened staff indices and for the A–B endpoints to snap to a measure head / end. Each chord carries a
    /// real note (not an empty rest) so this score counts as playable.
    private func parsedScore() -> Score {
        func measure() -> Measure {
            Measure(voices: [
                Voice(elements: [
                    .chord(Chord(duration: .quarter, notes: [Note(pitch: 60, tpc: 14)])),
                    .chord(Chord(duration: .quarter, notes: [Note(pitch: 60, tpc: 14)])),
                ]),
            ])
        }
        func staff() -> Staff {
            Staff(measures: (0 ..< 4).map { _ in measure() })
        }
        return Score(
            division: 480,
            parts: [
                Part(
                    id: "P0", trackName: "Vn",
                    instrument: Instrument(id: "v", channels: [InstrumentChannel(program: 40)]),
                    staves: [staff()],
                ),
                Part(
                    id: "P1", trackName: "Pno",
                    instrument: Instrument(id: "p", channels: [InstrumentChannel(program: 0)]),
                    staves: [staff(), staff()],
                ),
            ],
            metaTags: [:],
        )
    }

    @Test func `a successful parse makes the PDF playable and exposes the cursor rect`() async {
        let vm = makeVM(parser: StubPDFPlaybackParser(result: sampleResult()))

        await vm.parsePDFForPlayback(url: URL(filePath: "/tmp/whatever.pdf"))

        #expect(vm.isPDFPlaybackReady)
        #expect(vm.canPlayNow)
        #expect(vm.playbackScore != nil)
        #expect(vm.pdfPlaybackData?.geometry is StubPDFPlaybackGeometry)
        #expect(
            vm.pdfCursorRect(for: .beat(measureIndex: 0, tickInMeasure: 0))
                == PDFCursorRect(pageIndex: 0, rect: CGRect(x: 10, y: 20, width: 4, height: 90)),
        )
    }

    @Test func `no injected parser leaves the PDF display-only`() async {
        let vm = makeVM(parser: nil)

        await vm.parsePDFForPlayback(url: URL(filePath: "/tmp/whatever.pdf"))

        #expect(!vm.isPDFPlaybackReady)
        #expect(vm.pdfPlaybackData == nil)
    }

    @Test func `a parse failure leaves the PDF display-only`() async {
        let vm = makeVM(parser: StubPDFPlaybackParser(result: nil))

        await vm.parsePDFForPlayback(url: URL(filePath: "/tmp/whatever.pdf"))

        #expect(!vm.isPDFPlaybackReady)
        #expect(vm.pdfPlaybackData == nil)
    }

    /// The defect this test pins: a "print to PDF" export the OMR pipeline reads as ruled staff lines
    /// without any noteheads reconstructs full parts/staves/measures — but every voice slot is an
    /// empty chord (a rest). That must NOT report a playable transport, even though the parse itself
    /// succeeded and produced a structurally complete score.
    @Test func `a parse that succeeds but yields no notes leaves the PDF display-only`() async {
        let restsOnlyMeasure = Measure(voices: [
            Voice(elements: [.rest(duration: .quarter), .rest(duration: .quarter)]),
        ])
        let restsOnlyStaff = Staff(measures: (0 ..< 4).map { _ in restsOnlyMeasure })
        let restsOnlyScore = Score(division: 480, parts: [
            Part(id: "P0", instrument: Instrument(id: "i"), staves: [restsOnlyStaff]),
        ])
        let vm = makeVM(parser: StubPDFPlaybackParser(result: sampleResult(score: restsOnlyScore)))

        await vm.parsePDFForPlayback(url: URL(filePath: "/tmp/whatever.pdf"))

        #expect(!vm.isPDFPlaybackReady)
        #expect(vm.pdfPlaybackData == nil)
    }

    @Test func `the mixer addresses the parsed score's staves once the PDF is playable`() async {
        let controller = FakePlaybackController()
        let vm = makeVM(
            parser: StubPDFPlaybackParser(result: sampleResult(score: parsedScore())),
            controller: controller,
        )
        let pianoTop = StaffAddress(partIndex: 1, staffIndexInPart: 0)

        // Before the parse there is no playable score, so the mixer has no staff to address and reaches no engine.
        await vm.mixerModel.setStaffProgram(6, for: pianoTop)
        #expect(controller.staffInstrumentCalls.isEmpty)

        await vm.parsePDFForPlayback(url: URL(filePath: "/tmp/whatever.pdf"))
        await vm.mixerModel.setStaffProgram(6, for: pianoTop)

        // Violin takes flat index 0, so the piano's upper staff is 1.
        #expect(controller.staffInstrumentCalls.map(\.staff) == [1])
        #expect(controller.staffInstrumentCalls.map(\.program) == [6])
        #expect(vm.mixerModel.effectiveProgram(forPartIndex: 0) == 40)
    }

    @Test func `repeat endpoints snap against the parsed PDF score`() async {
        let controller = FakePlaybackController()
        let vm = makeVM(
            parser: StubPDFPlaybackParser(result: sampleResult(score: parsedScore())),
            controller: controller,
        )
        await vm.parsePDFForPlayback(url: URL(filePath: "/tmp/whatever.pdf"))

        vm.playbackSession.setManualCursor(.beat(measureIndex: 1, tickInMeasure: 0))
        await vm.repeatModel.setA()
        vm.playbackSession.setManualCursor(.beat(measureIndex: 2, tickInMeasure: 0))
        await vm.repeatModel.setB()

        #expect(vm.repeatModel.abRange?.start.measureIndex == 1)
        #expect(vm.repeatModel.abRange?.start.chordIndex == 0)
        #expect(vm.repeatModel.abRange?.end.measureIndex == 2)
        // Two chords per measure, so the measure's last chord is index 1.
        #expect(vm.repeatModel.abRange?.end.chordIndex == 1)
        // The loop range reached the engine at all: `forwardLoopRangeToController` bails when the repeat model can't
        // resolve a score, which is exactly what a PDF used to hit. (The mode is left `.off` — global, sticky state
        // this suite shouldn't write — so the forwarded range itself is nil.)
        #expect(!controller.loopRangeCalls.isEmpty)
    }
}

// MARK: - Stubs

private struct StubPDFPlaybackParser: PDFPlaybackParser {
    /// `nil` makes `parse` throw, standing in for an unreadable / unparseable PDF.
    let result: PDFPlaybackParseResult?

    func parse(pdfURL: URL) throws -> PDFPlaybackParseResult {
        guard let result else {
            throw DomainError.scoreParseFailed(reason: "stub failure")
        }
        return result
    }
}

private struct StubPDFPlaybackGeometry: PDFPlaybackGeometry {
    let pageSizes: [Int: CGSize]
    let cursorRect: PDFCursorRect?
    let hitCursor: ScoreCursor?

    func cursorRect(for _: ScoreCursor, in _: Score) -> PDFCursorRect? {
        cursorRect
    }

    func cursor(at _: CGPoint, pageIndex _: Int) -> ScoreCursor? {
        hitCursor
    }
}
