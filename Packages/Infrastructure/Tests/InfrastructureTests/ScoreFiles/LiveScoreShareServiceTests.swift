@testable import Domain
import Foundation
@testable import ScoreFiles
import SheetMusic
import Testing

struct LiveScoreShareServiceTests {
    private static func makeItem(localFileName: String) -> ScoreItem {
        ScoreItem(
            title: "T", composer: nil, instrumentationSummary: nil,
            localFileName: localFileName, contentHash: "h",
            sizeBytes: 0, lengthBeats: 0, defaultTempoBpm: 120,
            primaryKey: nil, addedAt: .init(timeIntervalSince1970: 0),
            lastOpenedAt: nil, tagIDs: [], isFavorite: false,
        )
    }

    /// Fake `ScoreAudioExporter` that captures its call args and writes a sentinel byte to the destination URL so the
    /// returned share URL can be inspected.
    private final class FakeAudioExporter: Domain.ScoreAudioExporter, @unchecked Sendable {
        var error: Error?
        private(set) var calls: [(score: Score, url: URL)] = []

        func exportM4A(score: Score, to url: URL) throws {
            calls.append((score, url))
            if let error {
                throw error
            }
            try Data([0]).write(to: url)
        }
    }

    /// Fake `ScorePDFRenderer` returning fixed bytes so PDF routing can be asserted without exercising CoreGraphics.
    private struct FakePDFRenderer: Domain.ScorePDFRenderer {
        let data: Data
        func renderPDF(score: Score, title: String) throws -> Data {
            data
        }
    }

    /// `AnnotationStore` returning a fixed layer, so availability can be driven without a database. `error`, when
    /// set, is thrown instead — simulating a genuine store read failure, distinct from a legitimately empty layer.
    private final class FakeAnnotationStore: Domain.AnnotationStore, @unchecked Sendable {
        var layer: AnnotationLayer?
        var error: Error?
        func annotationLayer(forScoreItem id: Domain.ScoreItemID) throws -> AnnotationLayer? {
            if let error {
                throw error
            }
            return layer
        }

        func saveAnnotationLayer(_ layer: AnnotationLayer) throws {}
        func deleteAnnotationLayer(forScoreItem id: Domain.ScoreItemID) throws {}
    }

    /// `AnnotatedPDFRendering` returning fixed bytes and recording which entry point ran.
    private final class FakeAnnotatedRenderer: Domain.AnnotatedPDFRendering, @unchecked Sendable {
        enum Call: Equatable { case engraved, original }
        private(set) var calls: [Call] = []
        var data = Data([0xAA])

        func renderAnnotatedEngravedPDF(
            score: Score, title: String, drawings: [DrawingAnchor],
        ) throws -> Data {
            calls.append(.engraved)
            return data
        }

        func renderAnnotatedOriginalPDF(basePDF: Data, drawings: [DrawingAnchor]) throws -> Data {
            calls.append(.original)
            return data
        }
    }

    private static func musicalDrawing() -> DrawingAnchor {
        DrawingAnchor(
            kind: .musical(MusicalAnchor(
                measureIndex: 0, tickInMeasure: 0, partIndex: 0, staffIndexInPart: 0,
                dxSp: 0, verticalOffsetSp: 0,
            )),
            encodedDrawing: Data(),
        )
    }

    private static func pageDrawing() -> DrawingAnchor {
        DrawingAnchor(kind: .page(PageAnchor(pageIndex: 0)), encodedDrawing: Data())
    }

    private static func layer(for id: Domain.ScoreItemID, drawings: [DrawingAnchor]) -> AnnotationLayer {
        AnnotationLayer(
            scoreItemID: id, drawings: drawings, textBoxes: [], updatedAt: .init(timeIntervalSince1970: 0),
        )
    }

    /// Lays out `Scores/` and `Share/` and writes a single fixture score so the gateway can resolve `Score.source` on
    /// load. Used by every `availableFormats` and `prepareShare` test below.
    private final class Rig {
        let tmp: TempDirectory
        let svc: LiveScoreShareService
        let scores: URL
        let shareTmp: URL
        let item: ScoreItem
        let audio: FakeAudioExporter
        let annotations: FakeAnnotationStore
        let annotated: FakeAnnotatedRenderer

        init(
            scoreData: Data, localFileName: String, pdfRenderer: any Domain.ScorePDFRenderer,
            annotationStore: FakeAnnotationStore, annotatedPDFRenderer: FakeAnnotatedRenderer,
        ) throws {
            tmp = try TempDirectory()
            scores = tmp.url.appending(path: "Scores")
            shareTmp = tmp.url.appending(path: "Share")
            try FileManager.default.createDirectory(at: scores, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: shareTmp, withIntermediateDirectories: true)
            try scoreData.write(to: scores.appending(path: localFileName))
            audio = FakeAudioExporter()
            annotations = annotationStore
            annotated = annotatedPDFRenderer
            svc = LiveScoreShareService(
                scoresDirectory: scores,
                shareTempDirectory: shareTmp,
                gateway: LiveScoreFileGateway(),
                audioExporter: audio,
                pdfRenderer: pdfRenderer,
                annotatedPDFRenderer: annotated,
                annotationStore: annotations,
            )
            item = LiveScoreShareServiceTests.makeItem(localFileName: localFileName)
        }
    }

    private static func makeRig(
        scoreData: Data,
        localFileName: String,
        pdfRenderer: any Domain.ScorePDFRenderer = CoreGraphicsPDFRenderer(),
        annotationStore: FakeAnnotationStore = FakeAnnotationStore(),
        annotatedPDFRenderer: FakeAnnotatedRenderer = FakeAnnotatedRenderer(),
    ) throws -> Rig {
        try Rig(
            scoreData: scoreData, localFileName: localFileName, pdfRenderer: pdfRenderer,
            annotationStore: annotationStore, annotatedPDFRenderer: annotatedPDFRenderer,
        )
    }

    @Test func `available formats reports the same five formats for every loadable item`() async throws {
        let rig = try Self.makeRig(
            scoreData: Fixtures.minimalMSCZData(), localFileName: "abc.mscz",
        )
        let formats = await rig.svc.availableFormats(for: rig.item).map(\.format)
        #expect(formats == [.museScoreV4, .museScoreV3, .pdf, .midi, .audioM4A])
    }

    @Test func `available formats flags the matching muse score version for MSCZ sources`() async throws {
        // The minimal fixture parses as MuseScore v4 — the matching share row must light up `isOriginal`.
        let rig = try Self.makeRig(
            scoreData: Fixtures.minimalMSCZData(), localFileName: "abc.mscz",
        )
        let options = await rig.svc.availableFormats(for: rig.item)
        #expect(options.first { $0.format == .museScoreV4 }?.isOriginal == true)
        #expect(options.first { $0.format == .museScoreV3 }?.isOriginal == false)
        #expect(options.first { $0.format == .pdf }?.isOriginal == false)
        #expect(options.first { $0.format == .midi }?.isOriginal == false)
        #expect(options.first { $0.format == .audioM4A }?.isOriginal == false)
    }

    @Test func `available formats flags the matching muse score version for MSCX sources`() async throws {
        let rig = try Self.makeRig(
            scoreData: Fixtures.minimalMSCXData(), localFileName: "abc.mscx",
        )
        let options = await rig.svc.availableFormats(for: rig.item)
        #expect(options.first { $0.format == .museScoreV4 }?.isOriginal == true)
        #expect(options.first { $0.format == .museScoreV3 }?.isOriginal == false)
        #expect(options.first { $0.format == .audioM4A }?.isOriginal == false)
    }

    @Test func `available formats leaves everything unflagged when source cannot load`() async throws {
        // No file on disk → gateway parse fails → no original flag.
        let tmp = try TempDirectory()
        let svc = LiveScoreShareService(
            scoresDirectory: tmp.url.appending(path: "Scores"),
            shareTempDirectory: tmp.url.appending(path: "Share"),
            gateway: LiveScoreFileGateway(),
            audioExporter: FakeAudioExporter(),
            pdfRenderer: CoreGraphicsPDFRenderer(),
            annotatedPDFRenderer: FakeAnnotatedRenderer(),
            annotationStore: FakeAnnotationStore(),
        )
        let options = await svc.availableFormats(for: Self.makeItem(localFileName: "missing.mscz"))
        #expect(options.allSatisfy { !$0.isOriginal })
    }

    // MARK: - prepareShare

    @Test func `prepare share returns original bytes when format matches source`() async throws {
        // mscz fixture parses as v4 → picking museScoreV4 must return the source bytes verbatim with the source
        // extension intact.
        let mscz = try Fixtures.minimalMSCZData()
        let rig = try Self.makeRig(scoreData: mscz, localFileName: "abc.mscz")

        let url = try await rig.svc.prepareShare(item: rig.item, format: .museScoreV4)
        #expect(url.deletingLastPathComponent().path == rig.shareTmp.path)
        #expect(url.pathExtension == "mscz")
        let onDisk = try Data(contentsOf: url)
        #expect(onDisk == mscz)
    }

    @Test func `prepare share returns original MSCX bytes for MSCX sources`() async throws {
        let mscx = try Fixtures.minimalMSCXData()
        let rig = try Self.makeRig(scoreData: mscx, localFileName: "abc.mscx")

        let url = try await rig.svc.prepareShare(item: rig.item, format: .museScoreV4)
        #expect(url.pathExtension == "mscx")
        let onDisk = try Data(contentsOf: url)
        #expect(onDisk == mscx)
    }

    @Test func `prepare share reencodes when format does not match source`() async throws {
        // v4 fixture re-encoded to v3 must produce loadable but distinct bytes.
        let mscz = try Fixtures.minimalMSCZData()
        let rig = try Self.makeRig(scoreData: mscz, localFileName: "abc.mscz")

        let url = try await rig.svc.prepareShare(item: rig.item, format: .museScoreV3)
        #expect(url.pathExtension == "mscz")
        let bytes = try Data(contentsOf: url)
        _ = try SheetMusic.loadScore(msczData: bytes)
        #expect(bytes != mscz)
    }

    @Test func `prepare share PDF starts with PDF magic`() async throws {
        let rig = try Self.makeRig(
            scoreData: Fixtures.minimalMSCZData(), localFileName: "abc.mscz",
        )
        let url = try await rig.svc.prepareShare(item: rig.item, format: .pdf)
        #expect(url.pathExtension == "pdf")
        let head = try Data(contentsOf: url).prefix(4)
        #expect(head == Data([0x25, 0x50, 0x44, 0x46])) // %PDF
    }

    @Test func `prepare share PDF writes the injected renderer's bytes`() async throws {
        let bytes = Data("PDFBYTES".utf8)
        let rig = try Self.makeRig(
            scoreData: Fixtures.minimalMSCZData(), localFileName: "abc.mscz",
            pdfRenderer: FakePDFRenderer(data: bytes),
        )
        let url = try await rig.svc.prepareShare(item: rig.item, format: .pdf)
        #expect(url.pathExtension == "pdf")
        #expect(try Data(contentsOf: url) == bytes)
    }

    @Test func `prepare share MIDI starts with M thd magic`() async throws {
        let rig = try Self.makeRig(
            scoreData: Fixtures.minimalMSCZData(), localFileName: "abc.mscz",
        )
        let url = try await rig.svc.prepareShare(item: rig.item, format: .midi)
        #expect(url.pathExtension == "mid")
        let head = try Data(contentsOf: url).prefix(4)
        #expect(head == Data([0x4D, 0x54, 0x68, 0x64])) // "MThd"
    }

    @Test func `prepare share twice overwrites`() async throws {
        let rig = try Self.makeRig(
            scoreData: Fixtures.minimalMSCZData(), localFileName: "abc.mscz",
        )
        let first = try await rig.svc.prepareShare(item: rig.item, format: .midi)
        let second = try await rig.svc.prepareShare(item: rig.item, format: .midi)
        #expect(first == second)
    }

    @Test func `prepare share audio m4a writes a file via the audio exporter`() async throws {
        let rig = try Self.makeRig(
            scoreData: Fixtures.minimalMSCZData(), localFileName: "abc.mscz",
        )

        let url = try await rig.svc.prepareShare(item: rig.item, format: .audioM4A)

        #expect(url.pathExtension == "m4a")
        #expect(url.deletingLastPathComponent().path == rig.shareTmp.path)
        #expect(rig.audio.calls.count == 1)
        #expect(rig.audio.calls.first?.url == url)
        #expect(FileManager.default.fileExists(atPath: url.path))
    }

    @Test func `prepare share audio m4a propagates exporter errors`() async throws {
        let rig = try Self.makeRig(
            scoreData: Fixtures.minimalMSCZData(), localFileName: "abc.mscz",
        )
        rig.audio.error = DomainError.scoreWriteFailed(reason: "no soundfont")

        await #expect(throws: DomainError.self) {
            try await rig.svc.prepareShare(item: rig.item, format: .audioM4A)
        }
    }

    // MARK: - Annotated formats

    @Test
    func `an unannotated score offers only the five plain formats`() async throws {
        let rig = try Self.makeRig(scoreData: Fixtures.minimalMSCZData(), localFileName: "s.mscz")
        let formats = await rig.svc.availableFormats(for: rig.item).map(\.format)
        #expect(formats == ScoreShareFormat.allOrdered)
    }

    @Test
    func `musical ink inserts the engraved annotated row directly after the plain PDF row`() async throws {
        let rig = try Self.makeRig(scoreData: Fixtures.minimalMSCZData(), localFileName: "s.mscz")
        rig.annotations.layer = Self.layer(for: rig.item.id, drawings: [Self.musicalDrawing()])
        let formats = await rig.svc.availableFormats(for: rig.item).map(\.format)
        #expect(formats == [.museScoreV4, .museScoreV3, .pdf, .annotatedPDF, .midi, .audioM4A])
    }

    @Test
    func `both annotated rows land between the plain PDF and MIDI rows, in order`() async throws {
        // A converted-PDF item — `localFileName` is the score (engravable), but `sourcePDFFileName` still names the
        // original PDF sidecar, so both the engraved and the original-PDF annotated rows are on offer at once.
        let rig = try Self.makeRig(scoreData: Fixtures.minimalMSCZData(), localFileName: "s.mscz")
        var item = rig.item
        item.sourcePDFFileName = "original.pdf"
        rig.annotations.layer = Self.layer(
            for: rig.item.id, drawings: [Self.musicalDrawing(), Self.pageDrawing()],
        )
        let formats = await rig.svc.availableFormats(for: item).map(\.format)
        #expect(formats == [
            .museScoreV4, .museScoreV3, .pdf, .annotatedPDF, .annotatedOriginalPDF, .midi, .audioM4A,
        ])
    }

    @Test
    func `page ink without an original PDF on the item adds no row`() async throws {
        let rig = try Self.makeRig(scoreData: Fixtures.minimalMSCZData(), localFileName: "s.mscz")
        rig.annotations.layer = Self.layer(for: rig.item.id, drawings: [Self.pageDrawing()])
        let formats = await rig.svc.availableFormats(for: rig.item).map(\.format)
        #expect(formats == ScoreShareFormat.allOrdered)
    }

    @Test
    func `no annotated row is ever flagged as the item's original bytes`() async throws {
        let rig = try Self.makeRig(scoreData: Fixtures.minimalMSCZData(), localFileName: "s.mscz")
        rig.annotations.layer = Self.layer(for: rig.item.id, drawings: [Self.musicalDrawing()])
        let options = await rig.svc.availableFormats(for: rig.item)
        for option in options where option.format.isAnnotated {
            #expect(!option.isOriginal)
        }
    }

    @Test
    func `the engraved annotated share routes to the renderer and writes the suffixed name`() async throws {
        let rig = try Self.makeRig(scoreData: Fixtures.minimalMSCZData(), localFileName: "s.mscz")
        rig.annotations.layer = Self.layer(for: rig.item.id, drawings: [Self.musicalDrawing()])
        let url = try await rig.svc.prepareShare(item: rig.item, format: .annotatedPDF)
        #expect(url.lastPathComponent == "T (annotated).pdf")
        #expect(rig.annotated.calls == [.engraved])
        #expect(try Data(contentsOf: url) == rig.annotated.data)
    }

    @Test
    func `an annotated share does not overwrite a plain PDF share of the same item`() async throws {
        let rig = try Self.makeRig(scoreData: Fixtures.minimalMSCZData(), localFileName: "s.mscz")
        rig.annotations.layer = Self.layer(for: rig.item.id, drawings: [Self.musicalDrawing()])
        let plain = try await rig.svc.prepareShare(item: rig.item, format: .pdf)
        let annotated = try await rig.svc.prepareShare(item: rig.item, format: .annotatedPDF)
        #expect(plain != annotated)
        #expect(FileManager.default.fileExists(atPath: plain.path))
        #expect(FileManager.default.fileExists(atPath: annotated.path))
    }

    @Test
    func `an annotated share of an item with no layer throws rather than shipping a blank`() async throws {
        let rig = try Self.makeRig(scoreData: Fixtures.minimalMSCZData(), localFileName: "s.mscz")
        await #expect(throws: DomainError.self) {
            try await rig.svc.prepareShare(item: rig.item, format: .annotatedPDF)
        }
    }

    @Test
    func `a genuine annotation store failure is distinct from an empty layer`() async throws {
        // `requireDrawings` must not fold "the store threw" and "the store returned nothing" into the same "no
        // annotations" error — a genuine read failure should surface as itself.
        let rig = try Self.makeRig(scoreData: Fixtures.minimalMSCZData(), localFileName: "s.mscz")
        rig.annotations.error = DomainError.persistenceFailed(reason: "disk error")
        do {
            _ = try await rig.svc.prepareShare(item: rig.item, format: .annotatedPDF)
            Issue.record("expected throw")
        } catch DomainError.persistenceFailed(reason: "disk error") {
            // Expected: the store's own error, not "annotated export: the item has no annotations".
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    // MARK: - annotatedOriginalPDF route

    @Test
    func `the original-PDF annotated share reads the file beside the item and writes the suffixed name`() async throws {
        // `localFileName` itself is the PDF (an unconverted-PDF item): `originalPDFFileName` falls back to it, and
        // the Rig already writes `scoreData` there — this is the only reason the unconverted-PDF row works, per the
        // doc comment on `ScoreItem.originalPDFFileName`.
        let pdfBytes = Data("%PDF-1.4\n%%EOF".utf8)
        let rig = try Self.makeRig(scoreData: pdfBytes, localFileName: "s.pdf")
        rig.annotations.layer = Self.layer(for: rig.item.id, drawings: [Self.pageDrawing()])

        let url = try await rig.svc.prepareShare(item: rig.item, format: .annotatedOriginalPDF)

        #expect(url.lastPathComponent == "T (original annotated).pdf")
        #expect(rig.annotated.calls == [.original])
        #expect(try Data(contentsOf: url) == rig.annotated.data)
    }

    @Test
    func `the original-PDF annotated share throws when the original PDF is missing from disk`() async throws {
        // `sourcePDFFileName` names a sidecar that was never written — the on-disk read must fail rather than
        // silently produce an empty/garbage export.
        let rig = try Self.makeRig(scoreData: Fixtures.minimalMSCZData(), localFileName: "s.mscz")
        var item = rig.item
        item.sourcePDFFileName = "missing.pdf"

        do {
            _ = try await rig.svc.prepareShare(item: item, format: .annotatedOriginalPDF)
            Issue.record("expected throw")
        } catch let DomainError.scoreFileNotFound(name) {
            #expect(name == "missing.pdf")
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test
    func `the original-PDF share names the item, not the score file, when there is no original PDF`() async throws {
        // Neither `sourcePDFFileName` nor a `.pdf` `localFileName` — this item never had an original PDF at all, so
        // there is no on-disk name to report. The thrown error must not claim the (perfectly present) score file
        // is what's missing.
        let rig = try Self.makeRig(scoreData: Fixtures.minimalMSCZData(), localFileName: "s.mscz")

        do {
            _ = try await rig.svc.prepareShare(item: rig.item, format: .annotatedOriginalPDF)
            Issue.record("expected throw")
        } catch let DomainError.scoreWriteFailed(reason) {
            #expect(reason == "annotated export: the item has no original PDF")
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }
}
