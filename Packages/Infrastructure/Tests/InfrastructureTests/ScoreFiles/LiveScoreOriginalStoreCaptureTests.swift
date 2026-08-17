import CryptoKit
import Domain
import Foundation
@testable import ScoreFiles
import Testing

@Suite("LiveScoreOriginalStore capture")
struct LiveScoreOriginalStoreCaptureTests {
    private func makeDirectory() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "original-store-\(UUID().uuidString)", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func item(localFileName: String) -> ScoreItem {
        ScoreItem(
            title: "t",
            composer: nil,
            instrumentationSummary: nil,
            localFileName: localFileName,
            contentHash: "current",
            sizeBytes: 1,
            lengthBeats: 1,
            defaultTempoBpm: 120,
            primaryKey: nil,
            addedAt: Date(timeIntervalSince1970: 0),
            lastOpenedAt: nil,
            tagIDs: [],
            isFavorite: false,
        )
    }

    @Test func `an mscz import is copied to a sidecar with its hash recorded`() async throws {
        let dir = makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let bytes = Data("imported".utf8)
        try bytes.write(to: dir.appending(path: "ID.mscz"))
        let store = LiveScoreOriginalStore(scoresDirectory: dir, gateway: FakeGateway())

        let captured = try await store.captureOriginalIfNeeded(for: item(localFileName: "ID.mscz"))

        #expect(captured.originalFileName == "ID.original.mscz")
        #expect(captured.originalContentHash == hex(bytes))
        #expect(captured.originalProvenance == .importTime)
        #expect(try Data(contentsOf: dir.appending(path: "ID.original.mscz")) == bytes)
    }

    @Test func `a second capture leaves the first sidecar alone`() async throws {
        let dir = makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let original = Data("imported".utf8)
        try original.write(to: dir.appending(path: "ID.mscz"))
        let store = LiveScoreOriginalStore(scoresDirectory: dir, gateway: FakeGateway())

        let first = try await store.captureOriginalIfNeeded(for: item(localFileName: "ID.mscz"))
        try Data("edited".utf8).write(to: dir.appending(path: "ID.mscz"))
        let second = try await store.captureOriginalIfNeeded(for: first)

        #expect(second.originalContentHash == first.originalContentHash)
        #expect(try Data(contentsOf: dir.appending(path: "ID.original.mscz")) == original)
    }

    /// The failure a database flag would have caused: the row's capture never got written, but the score file was
    /// already overwritten. Keying off the sidecar means the second attempt finds it and does not re-copy.
    @Test func `a capture whose row update was lost does not overwrite the sidecar`() async throws {
        let dir = makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let original = Data("imported".utf8)
        try original.write(to: dir.appending(path: "ID.mscz"))
        let store = LiveScoreOriginalStore(scoresDirectory: dir, gateway: FakeGateway())

        _ = try await store.captureOriginalIfNeeded(for: item(localFileName: "ID.mscz"))
        // Simulate the kill: the returned item is thrown away, and the file is overwritten by the edit that follows.
        try Data("edited".utf8).write(to: dir.appending(path: "ID.mscz"))

        let recovered = try await store.captureOriginalIfNeeded(for: item(localFileName: "ID.mscz"))

        #expect(recovered.originalContentHash == hex(original))
        #expect(try Data(contentsOf: dir.appending(path: "ID.original.mscz")) == original)
    }

    @Test func `a musicxml import adopts its own file and copies nothing`() async throws {
        let dir = makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let bytes = Data("<score-partwise/>".utf8)
        try bytes.write(to: dir.appending(path: "ID.musicxml"))
        let store = LiveScoreOriginalStore(scoresDirectory: dir, gateway: FakeGateway())

        let captured = try await store.captureOriginalIfNeeded(for: item(localFileName: "ID.musicxml"))

        #expect(captured.originalFileName == "ID.musicxml")
        #expect(captured.originalContentHash == hex(bytes))
        #expect(FileManager.default.fileExists(atPath: dir.appending(path: "ID.original.musicxml").path) == false)
    }

    @Test func `an orphaned musicxml beside an mscz is adopted instead of copied`() async throws {
        let dir = makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let orphan = Data("<score-partwise/>".utf8)
        try orphan.write(to: dir.appending(path: "ID.musicxml"))
        try Data("edited".utf8).write(to: dir.appending(path: "ID.mscz"))
        let store = LiveScoreOriginalStore(scoresDirectory: dir, gateway: FakeGateway())
        var subject = item(localFileName: "ID.mscz")
        subject.originalProvenance = .legacyUnknown

        let captured = try await store.captureOriginalIfNeeded(for: subject)

        #expect(captured.originalFileName == "ID.musicxml")
        #expect(captured.originalProvenance == .importTime)
        #expect(captured.originalContentHash == hex(orphan))
    }

    @Test func `an item with no file on disk is returned untouched`() async throws {
        let dir = makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = LiveScoreOriginalStore(scoresDirectory: dir, gateway: FakeGateway())

        let captured = try await store.captureOriginalIfNeeded(for: item(localFileName: "ID.mscz"))

        #expect(captured.originalFileName == nil)
    }
}

/// Minimal `ScoreFileGateway` double. Capture never parses, so every member throws; the revert tests replace this.
private struct FakeGateway: ScoreFileGateway {
    func detectFormat(fileName: String) -> ScoreFormat? {
        ScoreFormat.detect(filename: fileName)
    }

    // swiftlint:disable:next async_without_await
    func loadFileMetadata(fileURL _: URL) async throws -> ScoreFileSummary {
        throw DomainError.unsupportedFormat("test")
    }

    // swiftlint:disable:next async_without_await
    func loadScore(fileURL _: URL) async throws -> (score: Score, summary: ScoreFileSummary) {
        throw DomainError.unsupportedFormat("test")
    }

    // swiftlint:disable:next async_without_await
    func saveScore(_: Score, fileURL _: URL, format _: ScoreFormat) async throws {
        throw DomainError.unsupportedFormat("test")
    }
}
