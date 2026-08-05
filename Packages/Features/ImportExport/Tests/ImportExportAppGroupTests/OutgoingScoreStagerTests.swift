import Domain
import Foundation
@testable import ImportExportAppGroup
import Testing

struct OutgoingScoreStagerTests {
    private static let now = Date(timeIntervalSince1970: 100)

    /// Fresh temp dir standing in for the shared App Group container.
    private static func makeContainer() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "outgoing-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static func makeSourceFile(named name: String) throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "src-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appending(path: name, directoryHint: .notDirectory)
        try Data("score-bytes".utf8).write(to: file)
        return file
    }

    @Test func `stages the file and intent under the VocalTuner directory`() throws {
        let container = try Self.makeContainer()
        let source = try Self.makeSourceFile(named: "Air.mscz")

        let intent = try OutgoingScoreStager().stage(
            fileURL: source, displayName: "Air", format: "musescore",
            token: "TOKEN-1", into: container, now: Self.now,
        )

        let staged = container
            .appending(path: "IncomingScoresVT/TOKEN-1/files/Air.mscz", directoryHint: .notDirectory)
        #expect(FileManager.default.fileExists(atPath: staged.path))
        #expect(intent.files.first?.relativePath == "files/Air.mscz")
        #expect(intent.files.first?.originalName == "Air.mscz")
        #expect(intent.files.first?.format == "musescore")
        #expect(intent.source == "folino")
        #expect(intent.openAfter == true)
        #expect(intent.schemaVersion == 1)
        #expect(intent.token == "TOKEN-1")
    }

    @Test func `writes intent json the sibling can decode`() throws {
        let container = try Self.makeContainer()
        let source = try Self.makeSourceFile(named: "Air.mscz")

        try OutgoingScoreStager().stage(
            fileURL: source, displayName: "Air", format: "musescore",
            token: "TOKEN-2", into: container, now: Self.now,
        )

        let intentURL = container
            .appending(path: "IncomingScoresVT/TOKEN-2/intent.json", directoryHint: .notDirectory)
        let data = try Data(contentsOf: intentURL)
        // The `createdAt` must be an ISO-8601 string — a plain decoder must NOT be able to read it.
        #expect((try? JSONDecoder().decode(IncomingScoreIntent.self, from: data)) == nil)
        let decoded = try IncomingScoreIntent.decoder().decode(IncomingScoreIntent.self, from: data)
        #expect(decoded.createdAt == Self.now)
        #expect(decoded.source == "folino")
    }

    @Test func `sanitizes the display name into the staged filename`() throws {
        let container = try Self.makeContainer()
        let source = try Self.makeSourceFile(named: "A1B2C3.mscz")

        let intent = try OutgoingScoreStager().stage(
            fileURL: source, displayName: "Bach / Air: BWV 1068", format: "musescore",
            token: "TOKEN-3", into: container, now: Self.now,
        )

        // `/` and `:` are filesystem-hostile and become `_` (ScoreExportNaming.sanitize).
        #expect(intent.files.first?.originalName == "Bach _ Air_ BWV 1068.mscz")
        let staged = container.appending(
            path: "IncomingScoresVT/TOKEN-3/files/Bach _ Air_ BWV 1068.mscz", directoryHint: .notDirectory,
        )
        #expect(FileManager.default.fileExists(atPath: staged.path))
    }

    @Test func `re staging a token replaces the previous contents`() throws {
        let container = try Self.makeContainer()
        let first = try Self.makeSourceFile(named: "Old.mscz")
        let second = try Self.makeSourceFile(named: "New.mscz")

        try OutgoingScoreStager().stage(
            fileURL: first, displayName: "Old", format: "musescore",
            token: "TOKEN-4", into: container, now: Self.now,
        )
        try OutgoingScoreStager().stage(
            fileURL: second, displayName: "New", format: "musescore",
            token: "TOKEN-4", into: container, now: Self.now,
        )

        let filesDir = container
            .appending(path: "IncomingScoresVT/TOKEN-4/files", directoryHint: .isDirectory)
        let entries = try FileManager.default.contentsOfDirectory(atPath: filesDir.path)
        #expect(entries == ["New.mscz"])
    }

    @Test func `does not write into the inbound IncomingScores directory`() throws {
        let container = try Self.makeContainer()
        let source = try Self.makeSourceFile(named: "Air.mscz")

        try OutgoingScoreStager().stage(
            fileURL: source, displayName: "Air", format: "musescore",
            token: "TOKEN-5", into: container, now: Self.now,
        )

        // folino's own launch sweep drains IncomingScores/ unconditionally; an outbound score landing there
        // would be imported back into folino and scrubbed before VocalTuner ever saw it.
        let inbound = container.appending(path: "IncomingScores", directoryHint: .isDirectory)
        #expect(FileManager.default.fileExists(atPath: inbound.path) == false)
    }

    @Test func `rejects a traversal token without touching the container`() throws {
        let container = try Self.makeContainer()
        let source = try Self.makeSourceFile(named: "Air.mscz")
        // Something the container must survive: staging clears its token directory recursively, so a token that
        // escapes `IncomingScoresVT/` would aim that delete at the shared container root.
        let sibling = container.appending(path: "folino", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: sibling, withIntermediateDirectories: true)

        // Specifically the validation error, not just "something threw": a `FileManager` failure would also throw
        // here, and it would not prove the guard ran before any filesystem work.
        #expect(throws: CocoaError(.fileWriteInvalidFileName)) {
            try OutgoingScoreStager().stage(
                fileURL: source, displayName: "Air", format: "musescore",
                token: "../..", into: container, now: Self.now,
            )
        }

        #expect(FileManager.default.fileExists(atPath: sibling.path))
        let entries = try FileManager.default.contentsOfDirectory(atPath: container.path)
        #expect(entries == ["folino"])
    }

    @Test func `capability reader returns nil when no stamp exists`() throws {
        let container = try Self.makeContainer()
        #expect(VocalTunerCapabilityReader(sharedContainer: container).read() == nil)
    }

    @Test func `capability reader decodes a stamp`() throws {
        let container = try Self.makeContainer()
        let url = SharedScorePaths.vocalTunerCapabilitiesURL(in: container)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
        )
        try Data(#"{"protocolVersion":1,"vocalTunerAppVersion":"3.4.1"}"#.utf8).write(to: url)

        let stamp = VocalTunerCapabilityReader(sharedContainer: container).read()
        #expect(stamp == VocalTunerCapabilities(protocolVersion: 1, vocalTunerAppVersion: "3.4.1"))
    }

    @Test func `capability reader returns nil for malformed json`() throws {
        let container = try Self.makeContainer()
        let url = SharedScorePaths.vocalTunerCapabilitiesURL(in: container)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
        )
        try Data("not json".utf8).write(to: url)

        #expect(VocalTunerCapabilityReader(sharedContainer: container).read() == nil)
    }
}
