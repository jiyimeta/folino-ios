@testable import Audio
@testable import Domain
import Foundation
import SheetMusic
import SheetMusicAudio
import Testing

@MainActor
struct LiveScoreAudioExporterTests {
    /// Domain.SoundfontResolver fake that always throws on resolve. Used
    /// to verify the exporter's prefetch gate hard-fails before the
    /// PlaybackEngine is touched.
    private final class ThrowingDomainResolver: Domain.SoundfontResolver, @unchecked Sendable {
        struct Boom: Error {}
        func resolveSoundfont(bank _: Int, program _: Int, isDrums _: Bool) throws -> URL {
            throw Boom()
        }

        func cachedPatches() throws -> [SoundfontPatch] {
            []
        }

        func totalCacheSizeBytes() throws -> Int64 {
            0
        }

        func deletePatch(bank _: Int, program _: Int, isDrums _: Bool) throws {}
        func clearCache() throws {}
    }

    /// SheetMusicAudio.SoundfontResolver fake that the exporter passes
    /// to `PlaybackEngine`. The throwing-prefetch test never reaches
    /// the engine, so this just satisfies the constructor.
    private final class StubAudioResolver: SheetMusicAudio.SoundfontResolver, @unchecked Sendable {
        func soundfontURL(forBank _: UInt8, program _: UInt8, isDrums _: Bool) -> URL? {
            nil
        }

        var defaultGMSoundfontURL: URL? {
            nil
        }
    }

    @Test func `exportM4A throws scoreWriteFailed when a required patch cannot be resolved`() async throws {
        let score = try SheetMusic.loadScore(mscxData: Fixtures.minimalMSCXData())
        let exporter = LiveScoreAudioExporter(
            soundfontResolver: StubAudioResolver(),
            domainResolver: ThrowingDomainResolver(),
        )
        let tmp = try TempDirectory()
        let dest = tmp.url.appending(path: "out.m4a")

        await #expect(throws: DomainError.self) {
            try await exporter.exportM4A(score: score, to: dest)
        }
        #expect(!FileManager.default.fileExists(atPath: dest.path))
    }
}
