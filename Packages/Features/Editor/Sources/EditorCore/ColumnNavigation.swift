import Foundation
import SheetMusicCore

/// A vertical slice through one staff at one moment: which bar, and how far into it. The caret's real position
/// once it stops belonging to a voice (drum note entry's §5.4).
///
/// Ticks, not element indices, because that is the only address the voices of a bar agree on: voice 1's "beat 3"
/// and voice 2's are the same tick and almost never the same element index.
public struct ScoreColumn: Sendable, Equatable {
    public var staff: StaffAddress
    public var measureIndex: Int
    public var tick: Int

    public init(staff: StaffAddress, measureIndex: Int, tick: Int) {
        self.staff = staff
        self.measureIndex = measureIndex
        self.tick = tick
    }
}

/// Reading a staff as columns: where a slot sits, what covers a column in a given voice, and how to step.
///
/// Pure functions over a `Score` — no session state — so both the ← / → keys and the drum write resolution ask the
/// same questions, and Android gets the same answers by linking the same target.
///
/// The tick arithmetic is spelled out here rather than borrowed from `DurationChangeAlgorithm`, whose equivalents
/// are internal to `SheetMusicCore`. Every walk resolves `.measure` against the bar first: a full-measure rest is
/// "however long this bar is", and asking it for ticks unresolved traps.
public enum ColumnNavigation {
    /// The column `slot` begins at, or `nil` when the address names nothing.
    public static func column(of slot: VoiceElementID, in score: Score) -> ScoreColumn? {
        guard let voice = voice(at: slot, in: score), voice.elements.indices.contains(slot.elementIndex) else {
            return nil
        }
        let measureDuration = score.effectiveMeasureDuration(
            at: slot.staff, measureIndex: slot.measureIndex,
        )
        var tick = 0
        for element in voice.elements.prefix(slot.elementIndex) {
            guard case let .chord(chord) = element else { continue }
            tick += chord.duration.resolved(in: measureDuration).ticks(division: score.division)
        }
        return ScoreColumn(staff: slot.staff, measureIndex: slot.measureIndex, tick: tick)
    }

    /// The slot in `voiceIndex` that COVERS `column`, and how far into that slot the column falls.
    ///
    /// A non-zero `tickWithinSlot` is the "landed mid-rest" case: the caller splits the rest there before writing.
    /// `nil` when the measure has no such voice — which is what tells a drum key to create one.
    public static func slot(
        inVoice voiceIndex: Int, at column: ScoreColumn, in score: Score,
    ) -> (slot: VoiceElementID, tickWithinSlot: Int)? {
        let address = VoiceElementID(
            staff: column.staff, measureIndex: column.measureIndex, voiceIndex: voiceIndex, elementIndex: 0,
        )
        guard let voice = voice(at: address, in: score) else { return nil }
        let measureDuration = score.effectiveMeasureDuration(
            at: column.staff, measureIndex: column.measureIndex,
        )
        var tick = 0
        for (index, element) in voice.elements.enumerated() {
            guard case let .chord(chord) = element else { continue }
            let length = chord.duration.resolved(in: measureDuration).ticks(division: score.division)
            if column.tick < tick + length {
                return (
                    VoiceElementID(
                        staff: column.staff, measureIndex: column.measureIndex,
                        voiceIndex: voiceIndex, elementIndex: index,
                    ),
                    column.tick - tick,
                )
            }
            tick += length
        }
        return nil
    }

    /// The next column at or after `column`, walking into the following bar when this one is spent.
    ///
    /// `steppingBy` is the fallback when no voice has an onset ahead in this bar — an empty measure holds a single
    /// measure rest, whose only onset is tick 0, so without it → would jump the whole bar and beat 2 of an empty bar
    /// would be unreachable. The fallback never steps past the barline; the bar's end is the following bar's tick 0.
    public static func next(
        after column: ScoreColumn, in score: Score, steppingBy armed: NoteDuration?,
    ) -> ScoreColumn? {
        let onsets = onsetTicks(in: column.measureIndex, on: column.staff, in: score)
        if let ahead = onsets.first(where: { $0 > column.tick }) {
            return ScoreColumn(staff: column.staff, measureIndex: column.measureIndex, tick: ahead)
        }
        if let armed {
            let stepped = column.tick + armed.ticks(division: score.division)
            let measureTicks = score.effectiveMeasureDuration(
                at: column.staff, measureIndex: column.measureIndex,
            ).ticks(division: score.division)
            if stepped < measureTicks {
                return ScoreColumn(staff: column.staff, measureIndex: column.measureIndex, tick: stepped)
            }
        }
        let nextMeasure = column.measureIndex + 1
        guard measures(on: column.staff, in: score)?.indices.contains(nextMeasure) == true else { return nil }
        return ScoreColumn(staff: column.staff, measureIndex: nextMeasure, tick: 0)
    }

    /// The previous column, walking back into the preceding bar's LAST onset when this one opens the bar.
    ///
    /// No armed-duration fallback, deliberately: ← retreats along what is actually written, and an empty bar
    /// reached from its right-hand edge is walked back through by the onsets → laid down on the way in.
    public static func previous(before column: ScoreColumn, in score: Score) -> ScoreColumn? {
        let onsets = onsetTicks(in: column.measureIndex, on: column.staff, in: score)
        if let behind = onsets.last(where: { $0 < column.tick }) {
            return ScoreColumn(staff: column.staff, measureIndex: column.measureIndex, tick: behind)
        }
        let previousMeasure = column.measureIndex - 1
        guard previousMeasure >= 0,
              measures(on: column.staff, in: score)?.indices.contains(previousMeasure) == true
        else { return nil }
        let previousOnsets = onsetTicks(in: previousMeasure, on: column.staff, in: score)
        return ScoreColumn(staff: column.staff, measureIndex: previousMeasure, tick: previousOnsets.last ?? 0)
    }

    /// Every tick at which ANY voice of the bar starts a chord or rest, ascending and deduplicated. The union is
    /// the whole point: a column stops wherever either hand does.
    static func onsetTicks(in measureIndex: Int, on staff: StaffAddress, in score: Score) -> [Int] {
        guard let measures = measures(on: staff, in: score), measures.indices.contains(measureIndex) else {
            return []
        }
        let measureDuration = score.effectiveMeasureDuration(at: staff, measureIndex: measureIndex)
        var ticks: Set<Int> = []
        for voice in measures[measureIndex].voices {
            var tick = 0
            for element in voice.elements {
                guard case let .chord(chord) = element else { continue }
                ticks.insert(tick)
                tick += chord.duration.resolved(in: measureDuration).ticks(division: score.division)
            }
        }
        return ticks.sorted()
    }

    private static func measures(on staff: StaffAddress, in score: Score) -> [Measure]? {
        guard score.parts.indices.contains(staff.partIndex),
              score.parts[staff.partIndex].staves.indices.contains(staff.staffIndexInPart)
        else { return nil }
        return score.parts[staff.partIndex].staves[staff.staffIndexInPart].measures
    }

    private static func voice(at slot: VoiceElementID, in score: Score) -> Voice? {
        guard let measures = measures(on: slot.staff, in: score),
              measures.indices.contains(slot.measureIndex),
              measures[slot.measureIndex].voices.indices.contains(slot.voiceIndex)
        else { return nil }
        return measures[slot.measureIndex].voices[slot.voiceIndex]
    }
}
