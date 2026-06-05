import Domain
import Foundation
import SheetMusicCore

extension PlaybackPreferences {
    /// Builds the initial `PlaybackPreferences` to hand the playback engine when a score is first loaded into the
    /// controller: per-staff mixer states keyed by flattened staff index, with volume and program drawn from the user's
    /// `ReaderPreferences` overrides where set and from the score's authored channel values otherwise.
    static func initial(
        for score: Score,
        readerPreferences: ReaderPreferences,
        scoreItemID: Domain.ScoreItemID,
        defaultVolume: Double,
    ) -> PlaybackPreferences {
        let states = score.allStaves.enumerated().map { idx, entry in
            let bank = score.gmBank(at: entry.address) ?? 0
            let program = readerPreferences.staffProgramOverrides[entry.address]
                ?? score.gmProgram(at: entry.address)
                ?? 0
            let volume = readerPreferences.staffVolumeOverrides[entry.address]
                ?? score.initialStaffVolume(at: entry.address)
                ?? defaultVolume
            return StaffMixerState(
                staffIndex: idx,
                volume: volume,
                isMuted: false,
                isSolo: false,
                gmBank: bank,
                gmProgram: program,
            )
        }
        let globalA4 = UserDefaults.standard.object(forKey: ReaderGlobalSettingsKey.a4ReferenceHz) as? Double
            ?? A4Reference.standardHz
        return PlaybackPreferences(
            scoreItemID: scoreItemID,
            perStaff: states,
            tempoMultiplier: readerPreferences.tempoMultiplier ?? 1.0,
            abRepeat: readerPreferences.abRepeat,
            masterVolume: readerPreferences.masterVolume,
            a4ReferenceHz: A4Reference.effectiveHz(
                override: readerPreferences.a4ReferenceHz,
                globalDefault: globalA4,
            ),
        )
    }
}
