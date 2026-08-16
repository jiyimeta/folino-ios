import CryptoKit
import Domain
import Foundation
@testable import ScoreFiles
import SheetMusic
import Testing

@Suite("LiveScoreOriginalStore revert")
struct LiveScoreOriginalStoreRevertTests {
    private func makeDirectory() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "original-revert-\(UUID().uuidString)", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func item(localFileName: String, originalFileName: String) -> ScoreItem {
        var item = ScoreItem(
            title: "Kept",
            composer: "Kept",
            instrumentationSummary: "Kept",
            localFileName: localFileName,
            contentHash: "edited",
            sizeBytes: 6,
            lengthBeats: 1,
            defaultTempoBpm: 60,
            primaryKey: nil,
            addedAt: Date(timeIntervalSince1970: 0),
            lastOpenedAt: nil,
            tagIDs: [],
            isFavorite: false,
        )
        item.originalFileName = originalFileName
        item.originalContentHash = nil
        item.originalProvenance = .importTime
        return item
    }

    @Test func `a sidecar is written back over the score and then removed`() async throws {
        let dir = makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let original = Data("imported".utf8)
        try original.write(to: dir.appending(path: "ID.original.mscz"))
        try Data("edited".utf8).write(to: dir.appending(path: "ID.mscz"))
        let store = LiveScoreOriginalStore(scoresDirectory: dir, gateway: StubGateway())

        let reverted = try await store.revertToOriginal(
            item(localFileName: "ID.mscz", originalFileName: "ID.original.mscz"),
            restoringScoreInfo: false,
        )

        #expect(try Data(contentsOf: dir.appending(path: "ID.mscz")) == original)
        #expect(FileManager.default.fileExists(atPath: dir.appending(path: "ID.original.mscz").path) == false)
        #expect(reverted.localFileName == "ID.mscz")
        #expect(reverted.contentHash == hex(original))
        #expect(reverted.originalFileName == nil)
    }

    @Test func `a source file becomes the item's file again and the sibling mscz is deleted`() async throws {
        let dir = makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let original = Data("<score-partwise/>".utf8)
        try original.write(to: dir.appending(path: "ID.musicxml"))
        try Data("edited".utf8).write(to: dir.appending(path: "ID.mscz"))
        let store = LiveScoreOriginalStore(scoresDirectory: dir, gateway: StubGateway())

        let reverted = try await store.revertToOriginal(
            item(localFileName: "ID.mscz", originalFileName: "ID.musicxml"),
            restoringScoreInfo: false,
        )

        #expect(reverted.localFileName == "ID.musicxml")
        #expect(reverted.contentHash == hex(original))
        #expect(try Data(contentsOf: dir.appending(path: "ID.musicxml")) == original)
        #expect(FileManager.default.fileExists(atPath: dir.appending(path: "ID.mscz").path) == false)
    }

    @Test func `a missing original leaves the score alone and throws`() async throws {
        let dir = makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let edited = Data("edited".utf8)
        try edited.write(to: dir.appending(path: "ID.mscz"))
        let store = LiveScoreOriginalStore(scoresDirectory: dir, gateway: StubGateway())

        await #expect(throws: DomainError.self) {
            _ = try await store.revertToOriginal(
                item(localFileName: "ID.mscz", originalFileName: "ID.original.mscz"),
                restoringScoreInfo: false,
            )
        }
        #expect(try Data(contentsOf: dir.appending(path: "ID.mscz")) == edited)
    }

    @Test func `an item with no original throws rather than doing nothing quietly`() async throws {
        let dir = makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data("edited".utf8).write(to: dir.appending(path: "ID.mscz"))
        let store = LiveScoreOriginalStore(scoresDirectory: dir, gateway: StubGateway())
        var subject = item(localFileName: "ID.mscz", originalFileName: "ID.original.mscz")
        subject.originalFileName = nil

        await #expect(throws: DomainError.self) {
            _ = try await store.revertToOriginal(subject, restoringScoreInfo: false)
        }
    }

    @Test func `an original whose bytes no longer match its recorded hash is refused`() async throws {
        let dir = makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data("corrupted".utf8).write(to: dir.appending(path: "ID.original.mscz"))
        try Data("edited".utf8).write(to: dir.appending(path: "ID.mscz"))
        let store = LiveScoreOriginalStore(scoresDirectory: dir, gateway: StubGateway())
        var subject = item(localFileName: "ID.mscz", originalFileName: "ID.original.mscz")
        subject.originalContentHash = hex(Data("imported".utf8))

        await #expect(throws: DomainError.self) {
            _ = try await store.revertToOriginal(subject, restoringScoreInfo: false)
        }
    }

    @Test func `credits come back from the file when asked for`() async throws {
        let dir = makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data("imported".utf8).write(to: dir.appending(path: "ID.original.mscz"))
        try Data("edited".utf8).write(to: dir.appending(path: "ID.mscz"))
        let store = LiveScoreOriginalStore(scoresDirectory: dir, gateway: StubGateway())

        let reverted = try await store.revertToOriginal(
            item(localFileName: "ID.mscz", originalFileName: "ID.original.mscz"),
            restoringScoreInfo: true,
        )

        #expect(reverted.title == "Stub Title")
        #expect(reverted.composer == "Stub Composer")
    }
}

/// Returns a fixed summary for any file, so the tests assert the store's plumbing rather than the parser's output.
private struct StubGateway: ScoreFileGateway {
    func detectFormat(fileName: String) -> ScoreFormat? {
        ScoreFormat.detect(filename: fileName)
    }

    func loadFileMetadata(fileURL _: URL) throws -> ScoreFileSummary {
        Self.summary
    }

    func loadScore(fileURL _: URL) throws -> (score: Score, summary: ScoreFileSummary) {
        throw DomainError.unsupportedFormat("test")
    }

    func saveScore(_: Score, fileURL _: URL, format _: ScoreFormat) throws {
        throw DomainError.unsupportedFormat("test")
    }

    static let summary = ScoreFileSummary(
        title: "Stub Title",
        composer: "Stub Composer",
        instrumentationSummary: "Stub Instrumentation",
        lengthBeats: 17,
        defaultTempoBpm: 77,
        primaryKey: "F",
    )
}
