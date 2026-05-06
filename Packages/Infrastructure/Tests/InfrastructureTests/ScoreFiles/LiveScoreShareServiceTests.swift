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

    private static func makeService(in tmp: URL) -> LiveScoreShareService {
        LiveScoreShareService(
            scoresDirectory: tmp.appending(path: "Scores"),
            shareTempDirectory: tmp.appending(path: "Share"),
            gateway: LiveScoreFileGateway()
        )
    }

    @Test func availableFormatsAlwaysReturnsAllThree() throws {
        let tmp = try TempDirectory()
        let svc = Self.makeService(in: tmp.url)
        let item = Self.makeItem(localFileName: "abc.mscz")
        #expect(svc.availableFormats(for: item) == [.sourceFormat, .pdf, .midi])
    }

    @Test func resolvedSourceFormatMapsMSCXToMSCZ() throws {
        let tmp = try TempDirectory()
        let svc = Self.makeService(in: tmp.url)
        #expect(svc.resolvedSourceFormat(for: Self.makeItem(localFileName: "x.mscx")) == .mscz)
        #expect(svc.resolvedSourceFormat(for: Self.makeItem(localFileName: "x.mscz")) == .mscz)
        #expect(svc.resolvedSourceFormat(for: Self.makeItem(localFileName: "x.musicxml")) == .musicXML)
        #expect(svc.resolvedSourceFormat(for: Self.makeItem(localFileName: "x.mxl")) == .mxl)
    }

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

    @Test func prepareShareSourceMSCZCopiesBytesIntoTemp() async throws {
        let tmp = try TempDirectory()
        let scores = tmp.url.appending(path: "Scores")
        let shareTmp = tmp.url.appending(path: "Share")
        try FileManager.default.createDirectory(at: scores, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: shareTmp, withIntermediateDirectories: true)

        let mscz = try Fixtures.minimalMSCZData()
        let local = "abc.mscz"
        try mscz.write(to: scores.appending(path: local))

        let svc = LiveScoreShareService(
            scoresDirectory: scores,
            shareTempDirectory: shareTmp,
            gateway: LiveScoreFileGateway()
        )
        let item = Self.makeItem(localFileName: local)

        let url = try await svc.prepareShare(item: item, format: .sourceFormat)
        #expect(url.deletingLastPathComponent().path == shareTmp.path)
        #expect(url.pathExtension == "mscz")
        let onDisk = try Data(contentsOf: url)
        #expect(onDisk == mscz)
    }

    @Test func prepareShareWrapsMSCXAsMSCZ() async throws {
        let tmp = try TempDirectory()
        let scores = tmp.url.appending(path: "Scores")
        let shareTmp = tmp.url.appending(path: "Share")
        try FileManager.default.createDirectory(at: scores, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: shareTmp, withIntermediateDirectories: true)

        let mscx = try Fixtures.minimalMSCXData()
        let local = "abc.mscx"
        try mscx.write(to: scores.appending(path: local))

        let svc = LiveScoreShareService(
            scoresDirectory: scores,
            shareTempDirectory: shareTmp,
            gateway: LiveScoreFileGateway()
        )
        let item = Self.makeItem(localFileName: local)

        let url = try await svc.prepareShare(item: item, format: .sourceFormat)
        #expect(url.pathExtension == "mscz")
        // Round-trip: produced bytes load via SheetMusic's .mscz parser.
        let bytes = try Data(contentsOf: url)
        _ = try SheetMusic.loadScore(msczData: bytes)
    }

    @Test func prepareSharePDFStartsWithPDFMagic() async throws {
        let tmp = try TempDirectory()
        let scores = tmp.url.appending(path: "Scores")
        let shareTmp = tmp.url.appending(path: "Share")
        try FileManager.default.createDirectory(at: scores, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: shareTmp, withIntermediateDirectories: true)

        let mscz = try Fixtures.minimalMSCZData()
        let local = "abc.mscz"
        try mscz.write(to: scores.appending(path: local))

        let svc = LiveScoreShareService(
            scoresDirectory: scores,
            shareTempDirectory: shareTmp,
            gateway: LiveScoreFileGateway()
        )
        let item = Self.makeItem(localFileName: local)

        let url = try await svc.prepareShare(item: item, format: .pdf)
        #expect(url.pathExtension == "pdf")
        let head = try Data(contentsOf: url).prefix(4)
        #expect(head == Data([0x25, 0x50, 0x44, 0x46])) // %PDF
    }

    @Test func prepareShareMIDIStartsWithMThdMagic() async throws {
        let tmp = try TempDirectory()
        let scores = tmp.url.appending(path: "Scores")
        let shareTmp = tmp.url.appending(path: "Share")
        try FileManager.default.createDirectory(at: scores, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: shareTmp, withIntermediateDirectories: true)

        let mscz = try Fixtures.minimalMSCZData()
        let local = "abc.mscz"
        try mscz.write(to: scores.appending(path: local))

        let svc = LiveScoreShareService(
            scoresDirectory: scores,
            shareTempDirectory: shareTmp,
            gateway: LiveScoreFileGateway()
        )
        let item = Self.makeItem(localFileName: local)

        let url = try await svc.prepareShare(item: item, format: .midi)
        #expect(url.pathExtension == "mid")
        let head = try Data(contentsOf: url).prefix(4)
        #expect(head == Data([0x4D, 0x54, 0x68, 0x64])) // "MThd"
    }

    @Test func prepareShareTwiceOverwrites() async throws {
        let tmp = try TempDirectory()
        let scores = tmp.url.appending(path: "Scores")
        let shareTmp = tmp.url.appending(path: "Share")
        try FileManager.default.createDirectory(at: scores, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: shareTmp, withIntermediateDirectories: true)

        try Fixtures.minimalMSCZData().write(to: scores.appending(path: "abc.mscz"))
        let svc = LiveScoreShareService(
            scoresDirectory: scores,
            shareTempDirectory: shareTmp,
            gateway: LiveScoreFileGateway()
        )
        let item = Self.makeItem(localFileName: "abc.mscz")

        let first = try await svc.prepareShare(item: item, format: .midi)
        let second = try await svc.prepareShare(item: item, format: .midi)
        #expect(first == second)
    }
}
