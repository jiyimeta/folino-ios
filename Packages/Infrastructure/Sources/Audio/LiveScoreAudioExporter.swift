import Domain
import Foundation
import SheetMusicAudio
import SheetMusicCore

/// `Domain.ScoreAudioExporter` backed by `swift-sheet-music`'s offline `PlaybackEngine.exportAudioFile`.
///
/// Builds a one-shot `PlaybackEngine` per call (the engine is `@MainActor` and not designed to be reused for
/// back-to-back renders), so live playback through `LivePlaybackController` is unaffected — `exportAudioFile` itself
/// spins a dedicated `AVAudioEngine` internally for the offline render.
///
/// Soundfont policy: every distinct `(bank, program, isDrums)` triple the score uses is prefetched through the
/// `Domain.SoundfontResolver` before the engine is asked to prepare. A single resolve failure (e.g. offline + uncached)
/// propagates as `DomainError.scoreWriteFailed` and the offline render is never attempted. This is a deliberate
/// departure from `LivePlaybackController.scoreWithFallbackRewrites`, which silently falls back to bundled patches: an
/// audio export that secretly substitutes piano for, say, drums would be confusing once shared out of the app.
///
/// Metronome policy: `MetronomeController.isEnabled` defaults to `true` inside swift-sheet-music, so a fresh
/// `PlaybackEngine` would always embed the click track. The `metronomeEnabled` closure is evaluated per export so the
/// rendered file matches whatever the user has set in the Reader's global toggle (`@AppStorage`-backed under
/// `ReaderGlobalSettingsKey.metronomeEnabled`).
@MainActor
public final class LiveScoreAudioExporter: Domain.ScoreAudioExporter {
    private let soundfontResolver: any SheetMusicAudio.SoundfontResolver
    private let domainResolver: any Domain.SoundfontResolver
    private let metronomeEnabled: @Sendable () -> Bool

    public init(
        soundfontResolver: any SheetMusicAudio.SoundfontResolver,
        domainResolver: any Domain.SoundfontResolver,
        metronomeEnabled: @escaping @Sendable () -> Bool,
    ) {
        self.soundfontResolver = soundfontResolver
        self.domainResolver = domainResolver
        self.metronomeEnabled = metronomeEnabled
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
        engine.setMuted(forChannel: .metronome, to: !metronomeEnabled())

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
        } catch AudioExportError.cancelled {
            // The engine maps Task cancellation to AudioExportError.cancelled and deletes the partial file before
            // throwing. Re-raise as CancellationError so callers see the canonical Swift signal.
            throw CancellationError()
        } catch let error as AudioExportError {
            throw DomainError.scoreWriteFailed(reason: describe(error))
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
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                let detail = (error as NSError).localizedDescription
                throw DomainError.scoreWriteFailed(
                    reason: "soundfont unavailable (bank \(key.bank), program \(key.program)): \(detail)",
                )
            }
        }
    }

    /// Render an `AudioExportError` as a user-facing string. The raw enum description leaks Swift case syntax (e.g.
    /// `engineSetupFailed(underlying: "...")`) into the alert; this pulls the `underlying` payload out so the message
    /// is readable.
    private func describe(_ error: AudioExportError) -> String {
        switch error {
        case .noScorePrepared: "no score prepared"
        case .rangeNotInTimeline: "export range not in timeline"
        case let .formatUnsupportedOnThisOS(format): "format unsupported on this OS: \(format)"
        case let .engineSetupFailed(underlying): underlying
        case let .fileWriteFailed(underlying): underlying
        case .cancelled: "cancelled"
        }
    }
}
