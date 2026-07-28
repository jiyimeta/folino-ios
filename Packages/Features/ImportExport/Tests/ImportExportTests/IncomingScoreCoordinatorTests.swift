import Domain
import Foundation
@testable import ImportExport
import ImportExportAppGroup
import Testing
import UtilityCore

@MainActor
@Suite("IncomingScoreCoordinator")
struct IncomingScoreCoordinatorTests {
    // Fakes are shared with the Share-Extension drain's suite: both coordinators run the same
    // `SharedImportCoordinator` over the same `ScoreFileImporter`, so a second copy would only drift.
    private typealias FakeImporter = IncomingShareCoordinatorTests.FakeImporter
    private typealias SpyAnalytics = IncomingShareCoordinatorTests.SpyAnalytics
    private typealias SpyCrashReporter = IncomingShareCoordinatorTests.SpyCrashReporter

    // MARK: - Helpers

    private func makeContainer() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "score-handoff-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Stages a hand-off exactly the way a sibling app does, down to the encoder settings.
    @discardableResult
    private func stageToken(
        _ container: URL,
        token: String,
        source: String = "vocaltuner",
        openAfter: Bool = true,
        filenames: [String],
        createdAt: Date = .now,
    ) throws -> String {
        let filesURL = SharedScorePaths.tokenFilesURL(token: token, in: container)
        try FileManager.default.createDirectory(at: filesURL, withIntermediateDirectories: true)
        var files: [IncomingScoreIntent.File] = []
        for name in filenames {
            try Data("dummy".utf8).write(to: filesURL.appending(path: name, directoryHint: .notDirectory))
            files.append(.init(relativePath: "files/\(name)", originalName: name, format: "musicXML"))
        }
        let intent = IncomingScoreIntent(
            schemaVersion: 1,
            token: token,
            createdAt: createdAt,
            source: source,
            openAfter: openAfter,
            files: files,
        )
        try IncomingScoreIntent.encoder().encode(intent)
            .write(to: SharedScorePaths.tokenIntentURL(token: token, in: container))
        return token
    }

    private func makeCoordinator(
        container: URL,
        importer: FakeImporter = FakeImporter(),
        analytics: SpyAnalytics = SpyAnalytics(),
        crashReporter: SpyCrashReporter = SpyCrashReporter(),
    ) -> IncomingScoreCoordinator {
        IncomingScoreCoordinator(
            importer: importer,
            sharedContainer: container,
            analytics: analytics,
            crashReporter: crashReporter,
        )
    }

    // MARK: - Tests

    @Test func `imports the staged score, opens it, and scrubs the token`() async throws {
        let container = try makeContainer()
        defer { try? FileManager.default.removeItem(at: container) }
        let importer = FakeImporter()
        let coordinator = makeCoordinator(container: container, importer: importer)
        let token = try stageToken(container, token: UUID().uuidString, filenames: ["Etude.musicxml"])

        let result = await coordinator.drain(token: token)

        #expect(result.imported.count == 1)
        #expect(result.skipped.isEmpty)
        #expect(result.openAfter?.id == result.imported.first)
        // No playlist concept in the cross-app contract — everything lands in the library root.
        #expect(result.targetPlaylistID == nil)
        #expect(result.createdPlaylistID == nil)
        #expect(importer.committed.count == 1)
        #expect(!FileManager.default.fileExists(atPath: SharedScorePaths.tokenURL(token: token, in: container).path))
    }

    @Test func `openAfter false imports without nominating a score to open`() async throws {
        let container = try makeContainer()
        defer { try? FileManager.default.removeItem(at: container) }
        let coordinator = makeCoordinator(container: container)
        let token = try stageToken(
            container, token: UUID().uuidString, openAfter: false, filenames: ["a.musicxml"],
        )

        let result = await coordinator.drain(token: token)

        #expect(result.imported.count == 1)
        #expect(result.openAfter == nil)
    }

    @Test func `a score already in the library opens the existing copy without re-importing`() async throws {
        let container = try makeContainer()
        defer { try? FileManager.default.removeItem(at: container) }
        let existing = ScoreItem(
            id: ScoreItemID(),
            title: "Existing",
            composer: nil,
            instrumentationSummary: nil,
            localFileName: "existing.musicxml",
            contentHash: "dup.musicxml",
            sizeBytes: 1,
            lengthBeats: 1,
            defaultTempoBpm: 120,
            primaryKey: nil,
            addedAt: .now,
            lastOpenedAt: nil,
            tagIDs: [],
            isFavorite: false,
        )
        let importer = FakeImporter()
        importer.duplicateMap = ["dup.musicxml": existing]
        let coordinator = makeCoordinator(container: container, importer: importer)
        let token = try stageToken(container, token: UUID().uuidString, filenames: ["dup.musicxml"])

        let result = await coordinator.drain(token: token)

        #expect(result.imported.isEmpty)
        #expect(result.openAfter?.id == existing.id)
        if case let .duplicate(existingID, _) = result.skipped.first?.reason {
            #expect(existingID == existing.id)
        } else {
            Issue.record("expected a duplicate skip")
        }
    }

    @Test func `logs score_imported attributed to the originating app`() async throws {
        let container = try makeContainer()
        defer { try? FileManager.default.removeItem(at: container) }
        let analytics = SpyAnalytics()
        let coordinator = makeCoordinator(container: container, analytics: analytics)
        let token = try stageToken(container, token: UUID().uuidString, filenames: ["one.mscz"])

        _ = await coordinator.drain(token: token)

        let event = analytics.event(named: "score_imported")
        #expect(event?.parameters["source"] == .string("vocaltuner"))
        #expect(event?.parameters["is_duplicate"] == .bool(false))
    }

    @Test func `clamps an unexpected source rather than letting it into analytics`() async throws {
        let container = try makeContainer()
        defer { try? FileManager.default.removeItem(at: container) }
        let analytics = SpyAnalytics()
        let coordinator = makeCoordinator(container: container, analytics: analytics)
        let token = try stageToken(
            container, token: UUID().uuidString, source: "Some App v2.1 (beta)", filenames: ["one.mscz"],
        )

        _ = await coordinator.drain(token: token)

        #expect(analytics.event(named: "score_imported")?.parameters["source"] == .string("unknown"))
    }

    @Test func `a corrupt intent is scrubbed instead of wedging the queue`() async throws {
        let container = try makeContainer()
        defer { try? FileManager.default.removeItem(at: container) }
        let coordinator = makeCoordinator(container: container)
        let token = UUID().uuidString
        let tokenURL = SharedScorePaths.tokenURL(token: token, in: container)
        try FileManager.default.createDirectory(at: tokenURL, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: SharedScorePaths.tokenIntentURL(token: token, in: container))

        let result = await coordinator.drain(token: token)

        #expect(result.imported.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: tokenURL.path))
    }

    @Test func `a token naming a path outside the hand-off area is refused`() async throws {
        let container = try makeContainer()
        defer { try? FileManager.default.removeItem(at: container) }
        let coordinator = makeCoordinator(container: container)
        let soundfonts = container.appending(path: "Soundfonts", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: soundfonts, withIntermediateDirectories: true)

        let result = await coordinator.drain(token: "../Soundfonts")

        #expect(result.imported.isEmpty)
        #expect(FileManager.default.fileExists(atPath: soundfonts.path), "the scrub must not follow the traversal")
    }

    @Test func `sweeping drains every staged token oldest first`() async throws {
        let container = try makeContainer()
        defer { try? FileManager.default.removeItem(at: container) }
        let importer = FakeImporter()
        let coordinator = makeCoordinator(container: container, importer: importer)
        let later = try stageToken(
            container,
            token: UUID().uuidString,
            filenames: ["later.musicxml"],
            createdAt: Date(timeIntervalSince1970: 2000),
        )
        let earlier = try stageToken(
            container,
            token: UUID().uuidString,
            filenames: ["earlier.musicxml"],
            createdAt: Date(timeIntervalSince1970: 1000),
        )

        let result = await coordinator.drain(token: nil)

        #expect(result.imported.count == 2)
        let committedNames = importer.committed.map(\.0.sourceURL.lastPathComponent)
        #expect(committedNames == ["earlier.musicxml", "later.musicxml"])
        #expect(!FileManager.default.fileExists(atPath: SharedScorePaths.tokenURL(token: earlier, in: container).path))
        #expect(!FileManager.default.fileExists(atPath: SharedScorePaths.tokenURL(token: later, in: container).path))
    }

    @Test func `sweeping an empty or absent hand-off area is a no-op`() async throws {
        let container = try makeContainer()
        defer { try? FileManager.default.removeItem(at: container) }

        let result = await makeCoordinator(container: container).drain(token: nil)

        #expect(result.imported.isEmpty)
        #expect(result.skipped.isEmpty)
        #expect(result.openAfter == nil)
    }

    @Test func `a file that fails to parse is reported and recorded, not imported`() async throws {
        let container = try makeContainer()
        defer { try? FileManager.default.removeItem(at: container) }
        let importer = FakeImporter()
        importer.prepareError = NSError(domain: "Test", code: 1)
        let analytics = SpyAnalytics()
        let crash = SpyCrashReporter()
        let coordinator = makeCoordinator(
            container: container, importer: importer, analytics: analytics, crashReporter: crash,
        )
        let token = try stageToken(container, token: UUID().uuidString, filenames: ["bad.mscz"])

        let result = await coordinator.drain(token: token)

        #expect(result.imported.isEmpty)
        if case .parseFailed = result.skipped.first?.reason {} else {
            Issue.record("expected parseFailed")
        }
        #expect(analytics.event(named: "score_import_failed")?.parameters["reason"] == .string("parse_failed"))
        #expect(crash.recordedErrors.count == 1)
        #expect(analytics.event(named: "score_imported") == nil)
    }
}
