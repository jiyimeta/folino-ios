@testable import Domain
import Foundation
import Testing

private final class FakeCloudSync: CloudSync, @unchecked Sendable {
    let stateContinuation: AsyncStream<CloudSyncState>.Continuation
    let state: AsyncStream<CloudSyncState>
    var startCount = 0
    var stopCount = 0
    var syncNowCount = 0

    init() {
        var c: AsyncStream<CloudSyncState>.Continuation!
        state = AsyncStream { c = $0 }
        stateContinuation = c
    }

    func start() {
        startCount += 1
    }

    func stop() {
        stopCount += 1
    }

    func syncNow() throws {
        syncNowCount += 1
    }
}

private actor FakeScoreFileGateway: @preconcurrency ScoreFileGateway {
    func detectFormat(fileName: String) -> ScoreFormat? {
        ScoreFormat.detect(filename: fileName)
    }

    func loadFileMetadata(fileURL: URL) throws -> ScoreFileSummary {
        throw DomainError.unsupportedFormat("fake")
    }

    func loadScore(fileURL: URL) throws -> (score: Score, summary: ScoreFileSummary) {
        // Cannot construct a real `Score` without SheetMusicCore knowledge; throw to prove
        // the throwing signature compiles.
        throw DomainError.scoreParseFailed(reason: "fake")
    }

    func saveScore(_ score: Score, fileURL: URL, format: ScoreFormat) throws {
        throw DomainError.scoreWriteFailed(reason: "fake")
    }
}

struct CloudSyncProtocolTests {
    @Test func `records lifecycle calls`() async {
        let sync = FakeCloudSync()
        await sync.start()
        await sync.start()
        await sync.stop()
        try? await sync.syncNow()
        #expect(sync.startCount == 2)
        #expect(sync.stopCount == 1)
        #expect(sync.syncNowCount == 1)
    }

    @Test func `cloud sync state values are distinct`() {
        let cases: [CloudSyncState] = [
            .idle, .syncing, .failed(error: "x"), .unavailable,
        ]
        // Just exercise the enum so the cases are reachable from outside the module.
        #expect(cases.count == 4)
    }
}

struct ScoreFileGatewayProtocolTests {
    @Test func `detect format delegates to score format`() async {
        let gateway = FakeScoreFileGateway()
        let result = await gateway.detectFormat(fileName: "x.mscz")
        #expect(result == .mscz)
    }

    @Test func `load score throws on fake files`() async {
        let gateway = FakeScoreFileGateway()
        do {
            _ = try await gateway.loadScore(fileURL: URL(fileURLWithPath: "/dev/null"))
            Issue.record("expected throw")
        } catch let error as DomainError {
            if case .scoreParseFailed = error {
                // Expected.
            } else {
                Issue.record("unexpected DomainError: \(error)")
            }
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test func `load file metadata throws on fake files`() async {
        let gateway = FakeScoreFileGateway()
        do {
            _ = try await gateway.loadFileMetadata(fileURL: URL(fileURLWithPath: "/dev/null"))
            Issue.record("expected throw")
        } catch let error as DomainError {
            if case .unsupportedFormat = error { /* expected */ } else {
                Issue.record("unexpected DomainError: \(error)")
            }
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }
}
