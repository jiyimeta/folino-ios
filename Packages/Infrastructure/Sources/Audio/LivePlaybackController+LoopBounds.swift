import Domain
import Foundation
import SheetMusicAudio
import SheetMusicCore

extension LivePlaybackController {
    public func setLoopRange(_ range: ABRepeatRange?) {
        let wasPlaying = engine.state == .playing
        var didMutate = false
        if let range {
            // Only act when the persisted range resolves into engine cursor bounds. An unresolvable range (stale data
            // after a score with fewer measures, or an end measure with no chord/rest to anchor `throughEndOf` on)
            // leaves the engine's existing loop alone — silently clearing it would destroy the user's loop on a
            // corner-case bug.
            if let score = loadedScore,
               let bounds = Self.loopBounds(for: range, in: score)
            {
                engine.setLoop(from: .item(bounds.start), throughEndOf: bounds.last)
                didMutate = true
            }
        } else if engine.loopRange != nil {
            // Skip the engine's `clearLoop` when there's nothing to clear — it pauses the sequencer unconditionally, so
            // a no-op clear would still cause an audible pause / restart blip on the auto-resume path below.
            engine.clearLoop()
            didMutate = true
        }
        if didMutate, wasPlaying, let score = loadedScore {
            engine.play(in: score)
        }
    }

    /// Loop endpoints resolved against the loaded score. Both endpoints are `ScoreItemID`s rather than `.beat(...)`
    /// cursors because `PlaybackTimeline.frame(forCursor:)` requires an exact cursor match for `.beat` lookups, and the
    /// timeline registers `.item(...)` for any tick that already carries a chord onset (the typical shape for measure
    /// downbeats). A `.beat(measureIndex: M, tickInMeasure: 0)` lookup at such a tick would return nil and the engine's
    /// `setLoop` would silently no-op.
    struct LoopBounds: Equatable {
        let start: SheetMusicCore.ScoreItemID
        let last: SheetMusicCore.ScoreItemID
    }

    /// Map a persistence-typed `ABRepeatRange` to engine item-IDs. Returns `nil` when the start measure or end measure
    /// has no chord/rest elements to anchor on, or when the range is inverted.
    static func loopBounds(
        for range: ABRepeatRange, in score: Score,
    ) -> LoopBounds? {
        let measureCount = score.parts.first?.staves.first?.measures.count ?? 0
        guard measureCount > 0,
              range.start.measureIndex >= 0,
              range.end.measureIndex < measureCount,
              range.start.measureIndex <= range.end.measureIndex,
              let start = firstScoreItemID(
                  inMeasure: range.start.measureIndex, of: score,
              ),
              let last = lastScoreItemID(
                  inMeasure: range.end.measureIndex, of: score,
              )
        else { return nil }
        return LoopBounds(start: start, last: last)
    }

    /// First `.chord` element in the given measure (voice 0 of staff 0 — same spine the rest of the cursor mapping
    /// uses). Returns `.note(NoteID)` for sounding chords, `.rest(RestID)` for rests (empty chords). `nil` when the
    /// measure has no `.chord` elements at all.
    static func firstScoreItemID(
        inMeasure measureIndex: Int, of score: Score,
    ) -> SheetMusicCore.ScoreItemID? {
        guard let part = score.parts.first,
              let staff = part.staves.first,
              staff.measures.indices.contains(measureIndex),
              let voice = staff.measures[measureIndex].voices.first
        else { return nil }
        let staffAddress = StaffAddress(partIndex: 0, staffIndexInPart: 0)
        for (idx, element) in voice.elements.enumerated() {
            guard case let .chord(chord) = element else { continue }
            return scoreItemID(
                forChord: chord,
                staff: staffAddress,
                measureIndex: measureIndex,
                elementIndex: idx,
            )
        }
        return nil
    }

    /// Last `.chord` element in the given measure. Same shape as `firstScoreItemID` but walks to the end.
    static func lastScoreItemID(
        inMeasure measureIndex: Int, of score: Score,
    ) -> SheetMusicCore.ScoreItemID? {
        guard let part = score.parts.first,
              let staff = part.staves.first,
              staff.measures.indices.contains(measureIndex),
              let voice = staff.measures[measureIndex].voices.first
        else { return nil }
        let staffAddress = StaffAddress(partIndex: 0, staffIndexInPart: 0)
        var lastID: SheetMusicCore.ScoreItemID?
        for (idx, element) in voice.elements.enumerated() {
            guard case let .chord(chord) = element else { continue }
            lastID = scoreItemID(
                forChord: chord,
                staff: staffAddress,
                measureIndex: measureIndex,
                elementIndex: idx,
            )
        }
        return lastID
    }

    private static func scoreItemID(
        forChord chord: Chord,
        staff: StaffAddress,
        measureIndex: Int,
        elementIndex: Int,
    ) -> SheetMusicCore.ScoreItemID {
        if chord.notes.isEmpty {
            return .rest(RestID(
                staff: staff,
                measureIndex: measureIndex,
                voiceIndex: 0,
                elementIndex: elementIndex,
            ))
        }
        return .note(NoteID(
            staff: staff,
            measureIndex: measureIndex,
            voiceIndex: 0,
            elementIndex: elementIndex,
            noteIndexInChord: 0,
        ))
    }
}
