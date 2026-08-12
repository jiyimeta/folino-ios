import Domain
import Foundation

extension PlaybackPreferences {
    /// The user's saved overrides, keyed by strip, for the engine to apply on top of what it already seeded from
    /// the score. There is deliberately no score walk here: the strip list only exists once the engine has
    /// prepared the score, and a resolved per-strip list would re-send what `prepare` had just applied.
    static func initial(
        readerPreferences: ReaderPreferences,
        scoreItemID: Domain.ScoreItemID,
    ) -> PlaybackPreferences {
        let strips = Set(readerPreferences.stripVolumeOverrides.keys)
            .union(readerPreferences.stripProgramOverrides.keys)
        let states = strips.sorted {
            ($0.partIndex, $0.instrumentOrdinal) < ($1.partIndex, $1.instrumentOrdinal)
        }.map { strip in
            StripMixerState(
                strip: strip,
                volume: readerPreferences.stripVolumeOverrides[strip],
                gmProgram: readerPreferences.stripProgramOverrides[strip],
            )
        }
        let globalA4 = UserDefaults.standard.object(forKey: ReaderGlobalSettingsKey.a4ReferenceHz) as? Double
            ?? A4Reference.standardHz
        return PlaybackPreferences(
            scoreItemID: scoreItemID,
            perStrip: states,
            tempoMultiplier: readerPreferences.tempoMultiplier ?? 1.0,
            abRepeat: readerPreferences.abRepeat,
            masterVolume: readerPreferences.effectiveMasterVolume,
            a4ReferenceHz: A4Reference.effectiveHz(
                override: readerPreferences.a4ReferenceHz,
                globalDefault: globalA4,
            ),
            transposeSemitones: readerPreferences.effectiveTransposeSemitones,
        )
    }
}
