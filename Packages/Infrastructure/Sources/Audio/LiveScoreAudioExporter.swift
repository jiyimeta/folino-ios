import Domain
import Foundation
import SheetMusicAudio
import SheetMusicAudioSwiftySynth
import SheetMusicCore

/// `Domain.ScoreAudioExporter` backed by `swift-sheet-music`'s offline `PlaybackEngine.exportAudioFile`.
///
/// Builds a one-shot `PlaybackEngine` per call (the engine is `@MainActor` and not designed to be reused for
/// back-to-back renders), so live playback through `LivePlaybackController` is unaffected — `exportAudioFile` itself
/// spins a dedicated `AVAudioEngine` internally for the offline render.
///
/// Synth policy: the same `SwiftySynthBackend` live playback runs on. `exportAudioFile` renders through a second,
/// offline instance of an injected backend (`PlaybackEngine+ExportBackend`, ssm 1.15.0) and only falls back to the
/// built-in AUMIDISynth pipeline when no backend is injected — which is what folino used to do, so an exported file
/// was rendered by a different synth from the one the user had just been listening to: AUMIDISynth steals voices on
/// dense scores and sits at its own level.
///
/// Soundfont policy: the GM soundfont is provided by the `SheetMusicAudio.SoundfontResolver` passed at init time (a
/// `GMSoundfontResolver` in production). No per-patch prefetch is needed — the bundled lightweight preset covers every
/// GM program, and the optional high-quality download is handled separately by `LiveMuseScoreGeneralProvider`.
///
/// Metronome policy: `MetronomeController.isEnabled` defaults to `true` inside swift-sheet-music, so a fresh
/// `PlaybackEngine` would always embed the click track. The `metronomeEnabled` closure is evaluated per export so the
/// rendered file matches whatever the user has set in the Reader's global toggle (`@AppStorage`-backed under
/// `ReaderGlobalSettingsKey.metronomeEnabled`).
@MainActor
public final class LiveScoreAudioExporter: Domain.ScoreAudioExporter {
    private let soundfontResolver: any SheetMusicAudio.SoundfontResolver
    private let metronomeClickProvider: (any MetronomeClickProvider)?
    private let metronomeEnabled: @Sendable () -> Bool

    public init(
        soundfontResolver: any SheetMusicAudio.SoundfontResolver,
        metronomeClickProvider: (any MetronomeClickProvider)? = nil,
        metronomeEnabled: @escaping @Sendable () -> Bool,
    ) {
        self.soundfontResolver = soundfontResolver
        self.metronomeClickProvider = metronomeClickProvider
        self.metronomeEnabled = metronomeEnabled
    }

    public func exportM4A(score: Score, to url: URL) async throws {
        let backend = SwiftySynthBackend()
        let engine = PlaybackEngine(
            soundfontResolver: soundfontResolver,
            metronomeClickProvider: metronomeClickProvider,
            backend: backend,
            // `.hostManaged`: this engine renders offline and never reaches the output hardware, so it has no business
            // touching `AVAudioSession`. Under the default `.exclusiveOnPrepare` it took the session exclusively at
            // `prepare` — silencing whatever the user had playing in another app for a render that makes no sound.
            // Nor should it *relax* the session: exporting while the Reader is playing would otherwise rewrite the
            // category out from under live playback.
            audioSessionPolicy: .hostManaged,
        )
        do {
            try engine.prepare(score: score)
        } catch {
            throw DomainError.scoreWriteFailed(
                reason: "engine prepare failed: \((error as NSError).localizedDescription)",
            )
        }
        // `prepare` also builds this engine's LIVE synth, which an export never sounds — and a SwiftySynth holds its
        // parsed SoundFont in memory (the high-quality font is ~200 MB), so leaving it loaded would double the
        // footprint of an export against the offline instance `exportAudioFile` builds below. Tearing it down cancels
        // the in-flight load and drops the synth; `makeOfflineInstance` is stateless, so the export path is unaffected.
        backend.teardown()
        engine.setMuted(forChannel: .metronome, to: !metronomeEnabled())
        // The export engine is fresh, so its master gain starts at unity — which on the backend path renders ~14 dB
        // below what the Reader plays. Seed it with the same calibration live playback applies, at a user volume of
        // 1.0: `ReaderPreferences.masterVolume` is a per-score *practice* setting (and this protocol takes only a
        // `Score`), so an export renders at the score's authored level rather than at whatever the last listening
        // session was turned up to.
        engine.setMasterGain(Float(BackendOutputCalibration.gain))

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
