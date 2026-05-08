@testable import Domain
import Foundation
@testable import ScoreFiles
import SheetMusic
import Testing

@Suite struct LiveScoreShareServiceTests {
    private static func makeItem(localFileName: String) -> ScoreItem {
        ScoreItem(
            title: "T", composer: nil, instrumentationSummary: nil,
            localFileName: localFileName, contentHash: "h",
            sizeBytes: 0, lengthBeats: 0, defaultTempoBpm: 120,
            primaryKey: nil, addedAt: .init(timeIntervalSince1970: 0),
            lastOpenedAt: nil, tagIDs: [], isFavorite: false
        )
    }

    /// Lays out `Scores/` and `Share/` and writes a single fixture
    /// score so the gateway can resolve `Score.source` on load. Used
    /// by every `availableFormats` and `prepareShare` test below.
    private final class Rig {
        let tmp: TempDirectory
        let svc: LiveScoreShareService
        let scores: URL
        let shareTmp: URL
        let item: ScoreItem

        init(scoreData: Data, localFileName: String) throws {
            tmp = try TempDirectory()
            scores = tmp.url.appending(path: "Scores")
            shareTmp = tmp.url.appending(path: "Share")
            try FileManager.default.createDirectory(at: scores, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: shareTmp, withIntermediateDirectories: true)
            try scoreData.write(to: scores.appending(path: localFileName))
            svc = LiveScoreShareService(
                scoresDirectory: scores,
                shareTempDirectory: shareTmp,
                gateway: LiveScoreFileGateway()
            )
            item = LiveScoreShareServiceTests.makeItem(localFileName: localFileName)
        }
    }

    private static func makeRig(
        scoreData: Data,
        localFileName: String
    ) throws -> Rig {
        try Rig(scoreData: scoreData, localFileName: localFileName)
    }

    @Test func availableFormatsReportsTheSameFourFormatsForEveryLoadableItem() async throws {
        let rig = try Self.makeRig(
            scoreData: Fixtures.minimalMSCZData(), localFileName: "abc.mscz"
        )
        let formats = await rig.svc.availableFormats(for: rig.item).map(\.format)
        #expect(formats == [.museScoreV4, .museScoreV3, .pdf, .midi])
    }

    @Test func availableFormatsFlagsTheMatchingMuseScoreVersionForMSCZSources() async throws {
        // The minimal fixture parses as MuseScore v4 — the matching
        // share row must light up `isOriginal`.
        let rig = try Self.makeRig(
            scoreData: Fixtures.minimalMSCZData(), localFileName: "abc.mscz"
        )
        let options = await rig.svc.availableFormats(for: rig.item)
        #expect(options.first { $0.format == .museScoreV4 }?.isOriginal == true)
        #expect(options.first { $0.format == .museScoreV3 }?.isOriginal == false)
        #expect(options.first { $0.format == .pdf }?.isOriginal == false)
        #expect(options.first { $0.format == .midi }?.isOriginal == false)
    }

    @Test func availableFormatsFlagsTheMatchingMuseScoreVersionForMSCXSources() async throws {
        let rig = try Self.makeRig(
            scoreData: Fixtures.minimalMSCXData(), localFileName: "abc.mscx"
        )
        let options = await rig.svc.availableFormats(for: rig.item)
        #expect(options.first { $0.format == .museScoreV4 }?.isOriginal == true)
        #expect(options.first { $0.format == .museScoreV3 }?.isOriginal == false)
    }

    @Test func availableFormatsLeavesEverythingUnflaggedWhenSourceCannotLoad() async throws {
        // No file on disk → gateway parse fails → no original flag.
        let tmp = try TempDirectory()
        let svc = LiveScoreShareService(
            scoresDirectory: tmp.url.appending(path: "Scores"),
            shareTempDirectory: tmp.url.appending(path: "Share"),
            gateway: LiveScoreFileGateway()
        )
        let options = await svc.availableFormats(for: Self.makeItem(localFileName: "missing.mscz"))
        #expect(options.allSatisfy { !$0.isOriginal })
    }

    // MARK: - matchingFormat helper

    @Test func matchingFormatMapsKnownSources() {
        #expect(LiveScoreShareService.matchingFormat(for: .midi) == .midi)
        #expect(LiveScoreShareService.matchingFormat(for: .museScore(.v4)) == .museScoreV4)
        #expect(LiveScoreShareService.matchingFormat(for: .museScore(.v3)) == .museScoreV3)
        #expect(LiveScoreShareService.matchingFormat(for: .musicXML) == nil)
        #expect(LiveScoreShareService.matchingFormat(for: .pdf) == nil)
        #expect(LiveScoreShareService.matchingFormat(for: .unknown) == nil)
    }

    // MARK: - sanitize

    @Test func sanitizeTitleReplacesPathAndNullBytes() {
        #expect(LiveScoreShareService.sanitize(title: "a/b") == "a_b")
        #expect(LiveScoreShareService.sanitize(title: "a:b") == "a_b")
        #expect(LiveScoreShareService.sanitize(title: "a\\b") == "a_b")
        #expect(LiveScoreShareService.sanitize(title: "a\u{0000}b") == "a_b")
    }

    @Test func sanitizeTitleTrimsTo100Chars() {
        let input = String(repeating: "x", count: 250)
        #expect(LiveScoreShareService.sanitize(title: input).count == 100)
    }

    @Test func sanitizeTitleFallsBackToScoreWhenEmpty() {
        #expect(LiveScoreShareService.sanitize(title: "") == "score")
        #expect(LiveScoreShareService.sanitize(title: "///") == "score")
    }

    // MARK: - prepareShare

    @Test func prepareShareReturnsOriginalBytesWhenFormatMatchesSource() async throws {
        // mscz fixture parses as v4 → picking museScoreV4 must return
        // the source bytes verbatim with the source extension intact.
        let mscz = try Fixtures.minimalMSCZData()
        let rig = try Self.makeRig(scoreData: mscz, localFileName: "abc.mscz")

        let url = try await rig.svc.prepareShare(item: rig.item, format: .museScoreV4)
        #expect(url.deletingLastPathComponent().path == rig.shareTmp.path)
        #expect(url.pathExtension == "mscz")
        let onDisk = try Data(contentsOf: url)
        #expect(onDisk == mscz)
    }

    @Test func prepareShareReturnsOriginalMSCXBytesForMSCXSources() async throws {
        let mscx = try Fixtures.minimalMSCXData()
        let rig = try Self.makeRig(scoreData: mscx, localFileName: "abc.mscx")

        let url = try await rig.svc.prepareShare(item: rig.item, format: .museScoreV4)
        #expect(url.pathExtension == "mscx")
        let onDisk = try Data(contentsOf: url)
        #expect(onDisk == mscx)
    }

    @Test func prepareShareReencodesWhenFormatDoesNotMatchSource() async throws {
        // v4 fixture re-encoded to v3 must produce loadable but
        // distinct bytes.
        let mscz = try Fixtures.minimalMSCZData()
        let rig = try Self.makeRig(scoreData: mscz, localFileName: "abc.mscz")

        let url = try await rig.svc.prepareShare(item: rig.item, format: .museScoreV3)
        #expect(url.pathExtension == "mscz")
        let bytes = try Data(contentsOf: url)
        _ = try SheetMusic.loadScore(msczData: bytes)
        #expect(bytes != mscz)
    }

    @Test func prepareSharePDFStartsWithPDFMagic() async throws {
        let rig = try Self.makeRig(
            scoreData: Fixtures.minimalMSCZData(), localFileName: "abc.mscz"
        )
        let url = try await rig.svc.prepareShare(item: rig.item, format: .pdf)
        #expect(url.pathExtension == "pdf")
        let head = try Data(contentsOf: url).prefix(4)
        #expect(head == Data([0x25, 0x50, 0x44, 0x46])) // %PDF
    }

    @Test func prepareShareMIDIStartsWithMThdMagic() async throws {
        let rig = try Self.makeRig(
            scoreData: Fixtures.minimalMSCZData(), localFileName: "abc.mscz"
        )
        let url = try await rig.svc.prepareShare(item: rig.item, format: .midi)
        #expect(url.pathExtension == "mid")
        let head = try Data(contentsOf: url).prefix(4)
        #expect(head == Data([0x4D, 0x54, 0x68, 0x64])) // "MThd"
    }

    @Test func prepareShareTwiceOverwrites() async throws {
        let rig = try Self.makeRig(
            scoreData: Fixtures.minimalMSCZData(), localFileName: "abc.mscz"
        )
        let first = try await rig.svc.prepareShare(item: rig.item, format: .midi)
        let second = try await rig.svc.prepareShare(item: rig.item, format: .midi)
        #expect(first == second)
    }
}
