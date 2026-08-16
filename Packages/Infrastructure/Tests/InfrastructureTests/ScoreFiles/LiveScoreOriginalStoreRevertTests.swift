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
        let corrupted = Data("corrupted".utf8)
        let edited = Data("edited".utf8)
        try corrupted.write(to: dir.appending(path: "ID.original.mscz"))
        try edited.write(to: dir.appending(path: "ID.mscz"))
        let store = LiveScoreOriginalStore(scoresDirectory: dir, gateway: StubGateway())
        var subject = item(localFileName: "ID.mscz", originalFileName: "ID.original.mscz")
        subject.originalContentHash = hex(Data("imported".utf8))

        await #expect(throws: DomainError.self) {
            _ = try await store.revertToOriginal(subject, restoringScoreInfo: false)
        }
        // The hash check must run before the sidecar is written over the score, not after: a mismatch caught only
        // once the edit is already overwritten and the sidecar already deleted destroys the edit and recovers
        // nothing.
        #expect(try Data(contentsOf: dir.appending(path: "ID.mscz")) == edited)
        #expect(try Data(contentsOf: dir.appending(path: "ID.original.mscz")) == corrupted)
    }

    @Test func `an adopted source whose bytes no longer match its recorded hash is refused`() async throws {
        let dir = makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let corrupted = Data("corrupted".utf8)
        let edited = Data("edited".utf8)
        try corrupted.write(to: dir.appending(path: "ID.musicxml"))
        try edited.write(to: dir.appending(path: "ID.mscz"))
        let store = LiveScoreOriginalStore(scoresDirectory: dir, gateway: StubGateway())
        var subject = item(localFileName: "ID.mscz", originalFileName: "ID.musicxml")
        subject.originalContentHash = hex(Data("<score-partwise/>".utf8))

        await #expect(throws: DomainError.self) {
            _ = try await store.revertToOriginal(subject, restoringScoreInfo: false)
        }
        // Same ordering requirement as the sidecar branch: the sibling `.mscz` must not be deleted until the
        // adopt-target's hash has been confirmed.
        #expect(try Data(contentsOf: dir.appending(path: "ID.mscz")) == edited)
        #expect(try Data(contentsOf: dir.appending(path: "ID.musicxml")) == corrupted)
    }

    /// Every other test in this suite leaves `originalContentHash` `nil`, so they only ever exercise
    /// `verifiedHashAndSize`'s no-expectation branch — a real revert always has a hash recorded, and tightening the
    /// comparison (the wrong field, say) would break every one of them with nothing here to catch it (Important 7
    /// review fix).
    @Test func `a hash that matches the recorded original is accepted`() async throws {
        let dir = makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let original = Data("imported".utf8)
        try original.write(to: dir.appending(path: "ID.original.mscz"))
        try Data("edited".utf8).write(to: dir.appending(path: "ID.mscz"))
        let store = LiveScoreOriginalStore(scoresDirectory: dir, gateway: StubGateway())
        var subject = item(localFileName: "ID.mscz", originalFileName: "ID.original.mscz")
        subject.originalContentHash = hex(original)

        let reverted = try await store.revertToOriginal(subject, restoringScoreInfo: false)

        #expect(try Data(contentsOf: dir.appending(path: "ID.mscz")) == original)
        #expect(FileManager.default.fileExists(atPath: dir.appending(path: "ID.original.mscz").path) == false)
        #expect(reverted.contentHash == hex(original))
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

@Suite("LiveScoreOriginalStore discard")
struct LiveScoreOriginalStoreDiscardTests {
    private func makeDirectory() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "original-discard-\(UUID().uuidString)", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func item(localFileName: String, originalFileName: String?) -> ScoreItem {
        var item = ScoreItem(
            title: "t",
            composer: nil,
            instrumentationSummary: nil,
            localFileName: localFileName,
            contentHash: "c",
            sizeBytes: 1,
            lengthBeats: 1,
            defaultTempoBpm: 60,
            primaryKey: nil,
            addedAt: Date(timeIntervalSince1970: 0),
            lastOpenedAt: nil,
            tagIDs: [],
            isFavorite: false,
        )
        item.originalFileName = originalFileName
        item.originalContentHash = originalFileName == nil ? nil : "o"
        item.originalProvenance = originalFileName == nil ? nil : .conversionOutput
        return item
    }

    @Test func `discarding removes the sidecar and clears the columns`() async throws {
        let dir = makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data("baseline".utf8).write(to: dir.appending(path: "ID.original.mscz"))
        let store = LiveScoreOriginalStore(scoresDirectory: dir, gateway: StubGateway())

        let cleared = try await store.discardOriginal(
            for: item(localFileName: "ID.mscz", originalFileName: "ID.original.mscz"),
        )

        #expect(cleared.originalFileName == nil)
        #expect(cleared.originalContentHash == nil)
        #expect(cleared.originalProvenance == nil)
        #expect(FileManager.default.fileExists(atPath: dir.appending(path: "ID.original.mscz").path) == false)
    }

    @Test func `discarding never deletes a file the item still uses`() async throws {
        let dir = makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data("source".utf8).write(to: dir.appending(path: "ID.musicxml"))
        let store = LiveScoreOriginalStore(scoresDirectory: dir, gateway: StubGateway())

        _ = try await store.discardOriginal(for: item(localFileName: "ID.mscz", originalFileName: "ID.musicxml"))

        #expect(FileManager.default.fileExists(atPath: dir.appending(path: "ID.musicxml").path))
    }

    @Test func `discarding an item with no original is a no-op`() async throws {
        let dir = makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = LiveScoreOriginalStore(scoresDirectory: dir, gateway: StubGateway())
        let subject = item(localFileName: "ID.mscz", originalFileName: nil)
        #expect(try await store.discardOriginal(for: subject) == subject)
    }
}
