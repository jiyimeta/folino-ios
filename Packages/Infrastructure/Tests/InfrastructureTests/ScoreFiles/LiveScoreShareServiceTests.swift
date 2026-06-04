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
            if let error { throw error }
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

    /// Lays out `Scores/` and `Share/` and writes a single fixture score so the gateway can resolve `Score.source` on
    /// load. Used by every `availableFormats` and `prepareShare` test below.
    private final class Rig {
        let tmp: TempDirectory
        let svc: LiveScoreShareService
        let scores: URL
        let shareTmp: URL
        let item: ScoreItem
        let audio: FakeAudioExporter

        init(scoreData: Data, localFileName: String, pdfRenderer: any Domain.ScorePDFRenderer) throws {
            tmp = try TempDirectory()
            scores = tmp.url.appending(path: "Scores")
            shareTmp = tmp.url.appending(path: "Share")
            try FileManager.default.createDirectory(at: scores, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: shareTmp, withIntermediateDirectories: true)
            try scoreData.write(to: scores.appending(path: localFileName))
            audio = FakeAudioExporter()
            svc = LiveScoreShareService(
                scoresDirectory: scores,
                shareTempDirectory: shareTmp,
                gateway: LiveScoreFileGateway(),
                audioExporter: audio,
                pdfRenderer: pdfRenderer,
            )
            item = LiveScoreShareServiceTests.makeItem(localFileName: localFileName)
        }
    }

    private static func makeRig(
        scoreData: Data,
        localFileName: String,
        pdfRenderer: any Domain.ScorePDFRenderer = CoreGraphicsPDFRenderer(),
    ) throws -> Rig {
        try Rig(scoreData: scoreData, localFileName: localFileName, pdfRenderer: pdfRenderer)
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
}
