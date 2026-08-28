@testable import Audio
import AVFoundation
import Domain
import Foundation
import SheetMusicAudio
import SheetMusicCore
import Testing

/// Nested in `AudioEngineTests` for its `.serialized` trait — the assertions below read the process-wide
/// `AVAudioSession`, which any concurrently-running engine test would move under them.
extension AudioEngineTests {
    @MainActor
    @Suite("LiveScoreAudioExporter")
    struct LiveScoreAudioExporterTests {
        /// The export renders offline and never reaches the output hardware, so it must leave `AVAudioSession`
        /// exactly as it found it. Under the engine's default `.exclusiveOnPrepare` policy `prepare(score:)` claimed
        /// the session as `.playback` without `.mixWithOthers` — interrupting whatever the user had playing
        /// elsewhere, and rewriting the category under live playback when a score was already sounding.
        /// `LiveScoreAudioExporter` pins `.hostManaged` instead; this pins that down.
        ///
        /// Also covers the plainer contract: a full export completes and writes a file. With a resolver that has no
        /// SoundFont the render is silent, but every stage — `prepare`, the offline `SwiftySynthBackend`, the manual
        /// rendering loop, the M4A writer — still runs.
        @Test func `exports a file without touching the audio session`() async throws {
            let session = AVAudioSession.sharedInstance()
            let categoryBefore = session.category
            let optionsBefore = session.categoryOptions

            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let url = directory.appendingPathComponent("export.m4a")

            let exporter = LiveScoreAudioExporter(
                soundfontResolver: SilentSoundfontResolver(),
                metronomeEnabled: { false },
            )
            try await exporter.exportM4A(score: makeExportScore(measureCount: 2), to: url)

            #expect(FileManager.default.fileExists(atPath: url.path))
            let size = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int ?? 0
            #expect(size > 0)
            #expect(session.category == categoryBefore)
            #expect(session.categoryOptions == optionsBefore)
        }
    }
}

// MARK: - Fixtures

/// Resolves nothing. Supported for a host that injects a `SynthBackend` (no AUMIDISynth is ever built), which is what
/// the exporter does — see the `SoundfontResolver` doc comment on why a `nil`-resolving font is otherwise a trap.
private struct SilentSoundfontResolver: SoundfontResolver {
    func soundfontURL(forBank _: UInt8, program _: UInt8, isDrums _: Bool) -> URL? {
        nil
    }

    var defaultGMSoundfontURL: URL? {
        nil
    }
}

/// Single-part, single-staff score of quarter-note rests — enough for a real timeline and a real (silent) render.
private func makeExportScore(measureCount: Int) -> Score {
    let measures = (0 ..< measureCount).map { _ in
        Measure(voices: [Voice(elements: [.rest(duration: .quarter)])])
    }
    let part = Part(
        id: "P0",
        instrument: Instrument(id: "i", channels: [InstrumentChannel(program: 0)]),
        staves: [Staff(measures: measures)],
    )
    return Score(division: 480, parts: [part])
}
