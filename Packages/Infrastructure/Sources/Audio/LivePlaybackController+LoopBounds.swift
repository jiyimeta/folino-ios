import Domain
import Foundation
import SheetMusicAudio
import SheetMusicCore

extension LivePlaybackController {
    public func setLoopRange(_ range: ABRepeatRange?) {
        let wasPlaying = engine.state == .playing
        var didMutate = false
        if let range {
            // Only act when the persisted range resolves into engine cursor
            // bounds. An unresolvable range (stale data after a score with
            // fewer measures, or a last-measure case where the end measure
            // has no chord/rest to anchor `throughEndOf` on) leaves the
            // engine's existing loop alone — silently clearing it would
            // destroy the user's loop on a corner-case bug.
            if let score = loadedScore,
               let bounds = Self.loopBounds(for: range, in: score)
            {
                switch bounds {
                case let .beatRange(start, end):
                    engine.setLoop(from: start, to: end)
                case let .throughEndOf(start, last):
                    engine.setLoop(from: start, throughEndOf: last)
                }
                didMutate = true
            }
        } else if engine.loopRange != nil {
            // Skip the engine's `clearLoop` when there's nothing to clear —
            // it pauses the sequencer unconditionally, so a no-op clear
            // would still cause an audible pause / restart blip on the
            // auto-resume path below.
            engine.clearLoop()
            didMutate = true
        }
        if didMutate, wasPlaying, let score = loadedScore {
            engine.play(in: score)
        }
    }

    /// Half-open loop interval resolved against the loaded score. The
    /// caller maps each case to the matching `PlaybackEngine.setLoop`
    /// overload — `.beatRange` to `setLoop(from:to:)`,
    /// `.throughEndOf` to `setLoop(from:throughEndOf:)`. Latter is used
    /// when the loop covers the last measure of the score and there's
    /// no measure-`N+1` downbeat to half-open at.
    enum LoopBounds: Equatable {
        case beatRange(start: ScoreCursor, end: ScoreCursor)
        case throughEndOf(start: ScoreCursor, last: SheetMusicCore.ScoreItemID)
    }

    /// Map a persistence-typed `ABRepeatRange` to engine-typed cursor
    /// bounds. Returns `nil` when the score has no measures or the
    /// range can't be resolved (e.g. last-measure case but the end
    /// measure has no chord/rest elements to anchor `throughEndOf` on).
    static func loopBounds(
        for range: ABRepeatRange, in score: Score
    ) -> LoopBounds? {
        let measureCount = score.parts.first?.staves.first?.measures.count ?? 0
        guard measureCount > 0,
              range.start.measureIndex >= 0,
              range.end.measureIndex < measureCount,
              range.start.measureIndex <= range.end.measureIndex
        else { return nil }
        let start = ScoreCursor.beat(
            measureIndex: range.start.measureIndex, tickInMeasure: 0
        )
        let endNext = range.end.measureIndex + 1
        if endNext < measureCount {
            let end = ScoreCursor.beat(
                measureIndex: endNext, tickInMeasure: 0
            )
            return .beatRange(start: start, end: end)
        }
        guard let last = lastScoreItemID(
            inMeasure: range.end.measureIndex, of: score
        ) else { return nil }
        return .throughEndOf(start: start, last: last)
    }

    /// Last `.chord` element in the given measure (voice 0 of staff 0
    /// — same spine the rest of the cursor mapping uses). Returns a
    /// `.note(NoteID)` for chords with notes, `.rest(RestID)` for
    /// rests (empty chords). `nil` when the measure has no `.chord`
    /// elements at all (a measure of clef / time-sig / key-sig only).
    static func lastScoreItemID(
        inMeasure measureIndex: Int, of score: Score
    ) -> SheetMusicCore.ScoreItemID? {
        guard let part = score.parts.first,
              let staff = part.staves.first,
              staff.measures.indices.contains(measureIndex) else { return nil }
        guard let voice = staff.measures[measureIndex].voices.first else {
            return nil
        }
        let elements = voice.elements
        let staffAddress = StaffAddress(partIndex: 0, staffIndexInPart: 0)
        var lastID: SheetMusicCore.ScoreItemID?
        for (idx, element) in elements.enumerated() {
            guard case let .chord(chord) = element else { continue }
            if chord.notes.isEmpty {
                lastID = .rest(RestID(
                    staff: staffAddress,
                    measureIndex: measureIndex,
                    voiceIndex: 0,
                    elementIndex: idx
                ))
            } else {
                lastID = .note(NoteID(
                    staff: staffAddress,
                    measureIndex: measureIndex,
                    voiceIndex: 0,
                    elementIndex: idx,
                    noteIndexInChord: 0
                ))
            }
        }
        return lastID
    }
}
