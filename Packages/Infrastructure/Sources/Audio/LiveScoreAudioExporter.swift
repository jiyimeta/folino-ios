import Domain
import Foundation
import SheetMusicAudio
import SheetMusicCore

/// `Domain.ScoreAudioExporter` backed by `swift-sheet-music`'s
/// offline `PlaybackEngine.exportAudioFile`.
///
/// Builds a one-shot `PlaybackEngine` per call (the engine is
/// `@MainActor` and not designed to be reused for back-to-back
/// renders), so live playback through `LivePlaybackController` is
/// unaffected — `exportAudioFile` itself spins a dedicated
/// `AVAudioEngine` internally for the offline render.
///
/// Soundfont policy: every distinct `(bank, program, isDrums)` triple
/// the score uses is prefetched through the `Domain.SoundfontResolver`
/// before the engine is asked to prepare. A single resolve failure
/// (e.g. offline + uncached) propagates as
/// `DomainError.scoreWriteFailed` and the offline render is never
/// attempted. This is a deliberate departure from
/// `LivePlaybackController.scoreWithFallbackRewrites`, which silently
/// falls back to bundled patches: an audio export that secretly
/// substitutes piano for, say, drums would be confusing once shared
/// out of the app.
@MainActor
public final class LiveScoreAudioExporter: Domain.ScoreAudioExporter {
    private let soundfontResolver: any SheetMusicAudio.SoundfontResolver
    private let domainResolver: any Domain.SoundfontResolver

    public init(
        soundfontResolver: any SheetMusicAudio.SoundfontResolver,
        domainResolver: any Domain.SoundfontResolver,
    ) {
        self.soundfontResolver = soundfontResolver
        self.domainResolver = domainResolver
    }

    public func exportM4A(score: Score, to url: URL) async throws {
        try await prefetchAllPatches(in: score)

        let engine = PlaybackEngine(soundfontResolver: soundfontResolver)
        do {
            try engine.prepare(score: score)
        } catch {
            throw DomainError.scoreWriteFailed(
                reason: "engine prepare failed: \((error as NSError).localizedDescription)",
            )
        }

        do {
            try await engine.exportAudioFile(
                to: url,
                score: score,
                format: .m4a(.init(
                    sampleRate: 44100,
                    bitRate: 128_000,
                    channels: .stereo,
                )),
                range: .full,
            )
        } catch let error as AudioExportError {
            throw DomainError.scoreWriteFailed(reason: "\(error)")
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw DomainError.scoreWriteFailed(
                reason: (error as NSError).localizedDescription,
            )
        }
    }

    private func prefetchAllPatches(in score: Score) async throws {
        let keys = LivePlaybackController.distinctPatchKeys(in: score)
        for key in keys {
            do {
                _ = try await domainResolver.resolveSoundfont(
                    bank: key.bank,
                    program: key.program,
                    isDrums: key.isDrums,
                )
            } catch {
                let detail = (error as NSError).localizedDescription
                throw DomainError.scoreWriteFailed(
                    reason: "soundfont unavailable (bank \(key.bank), program \(key.program)): \(detail)",
                )
            }
        }
    }
}
