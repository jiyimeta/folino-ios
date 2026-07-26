import SheetMusicCore
import SwiftUI

/// Top line of the Playback Inspector's tempo row: the engraved beat marking (glyph + value, tap to reset) and the ±
/// stepper.
///
/// Isolated into its own `View` so the high-frequency `session.playbackCursor` read stays leaf-scoped — only this line
/// re-renders per cursor tick, not the enclosing inspector `List`. Reading the cursor in `PlaybackInspectorScreen.body`
/// instead rebuilt the whole `List` every note during playback, which interrupted scrolling of the per-part program
/// `Menu`. The marking governing the cursor supplies the beat note + printed value; `cursorTempoKey` (the section's
/// quarter bps) keys the roll animation — it changes only on a score-origin tempo change, not a slider / stepper edit.
/// `nil` (no cursor yet) resolves to the opening tempo.
struct TempoReadoutLine: View {
    let tempoModel: TempoModel
    let session: ReaderPlaybackSession
    let score: Score
    let referenceBpm: Double
    let minBpm: Double
    let maxBpm: Double

    var body: some View {
        // Stepper bumps the reference BPM by 1 and commits — one notch == one whole BPM at the opening tempo.
        let stepperBpm = Binding<Double>(
            get: { (tempoModel.displayMultiplier * referenceBpm).rounded() },
            set: { newValue in
                let clamped = min(max(newValue.rounded(), minBpm), maxBpm)
                Task { await tempoModel.commitMultiplier(clamped / referenceBpm) }
            },
        )
        let governing = score.governingTempo(at: session.playbackCursor)
        let beatGlyph = governing?.beatGlyph ?? "\u{E1D5}"
        let beatValue = Int(((governing?.beatsPerMinute ?? 120) * tempoModel.displayMultiplier).rounded())
        let cursorTempoKey = governing?.beatsPerSecond ?? 2.0
        // The readout/reset Button rides in the Stepper's own label so the List treats this as a labeled form row and
        // gives the `−`/`+` the light `tertiarySystemFill`, matching the staff-size / transpose steppers. A bare
        // `.labelsHidden()` Stepper renders as a standalone control with a darker fill that read as inconsistent.
        Stepper(value: stepperBpm, in: minBpm ... maxBpm, step: 1) {
            HStack(spacing: 8) {
                Button {
                    Task { await tempoModel.resetMultiplier() }
                } label: {
                    HStack(spacing: 4) {
                        TempoBeatGlyph(glyph: beatGlyph, fontSize: 18)
                        Text(verbatim: "= \(beatValue)")
                            .font(.callout.monospacedDigit())
                            .foregroundStyle(.primary)
                            .contentTransition(.numericText(value: Double(beatValue)))
                    }
                    .animation(.default, value: cursorTempoKey)
                }
                Spacer()
            }
        }
    }
}
