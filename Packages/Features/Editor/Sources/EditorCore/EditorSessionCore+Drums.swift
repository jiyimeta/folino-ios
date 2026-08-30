import Foundation
import SheetMusicCore

/// Drum note entry: whether the pad is on a percussion staff at all, which of its keys are sounding where the
/// caret is, and what pressing one does (drum note entry's §5.1, §5.3 and §5.5).
///
/// All of it here rather than in a host, because all of it is a decision — and a decision written as an
/// `EditorViewModel` method is one Android has to write a second time. Only the pad's SwiftUI is iOS-only.
extension EditorSessionCore {
    // MARK: - Which pad the score is asking for

    /// Whether the staff the caret is on is a percussion kit.
    ///
    /// There is no manual drum-mode switch: the score already says which kind of staff it is, and an extra toggle
    /// would be a second source of truth the user has to keep in sync (§5.1).
    public var isDrumStaffActive: Bool {
        guard let staff = caretColumn?.staff ?? Self.slot(of: caretItem)?.staff else { return false }
        return instrument(on: staff)?.useDrumset ?? false
    }

    /// The pad's keys with each one's engraving taken from THIS score's kit — the layout the pad should draw.
    public var resolvedDrumPadLayout: DrumPadLayout {
        guard let staff = caretColumn?.staff ?? Self.slot(of: caretItem)?.staff,
              let instrument = instrument(on: staff)
        else { return drumPadLayout }
        return drumPadLayout.resolved(against: instrument)
    }

    /// The drum pitches sounding in the caret's column, across every voice.
    ///
    /// What makes the pad readable while correcting an imported chart — and the property that lets the keys be
    /// toggles at all: a lit key means "this instrument is here", so pressing it takes it away (§5.3).
    public var litDrumPitches: Set<Int> {
        guard let score, let column = caretColumn else { return [] }
        var pitches: Set<Int> = []
        for voiceIndex in voiceIndices(at: column, in: score) {
            guard let resolved = ColumnNavigation.slot(inVoice: voiceIndex, at: column, in: score),
                  resolved.tickWithinSlot == 0,
                  case let .chord(chord)? = score[resolved.slot]
            else { continue }
            pitches.formUnion(chord.notes.map(\.pitch))
        }
        return pitches
    }

    // MARK: - Pressing a key

    /// Toggles `key`'s instrument in the caret's column, in the voice the key belongs to (§5.5).
    ///
    /// One press is one `CompositeEditCommand`, so one tap is one undo step. The sequence:
    ///
    /// 1. the key names the voice;
    /// 2. a measure without that voice grows one, filled with rests — `.createVoice` plans to nothing when it is
    ///    already there, so it can ride unconditionally;
    /// 3. a pitch the score's kit does not describe gets a `GMDrumset` row, as the composite's first member —
    ///    without it the layout falls back to the pitched diatonic formula and draws the note on a completely wrong
    ///    line, visible only for instruments the chart never used, which is exactly how it would ship unnoticed;
    /// 4. and then, against whatever covers the column in that voice:
    ///    - a chord already holding this pitch → take it away (the engine collapses a chord it empties to a rest);
    ///    - a chord without it → add it, with its notehead;
    ///    - a rest starting at the column → write it there at the armed length;
    ///    - a rest the column falls INSIDE → split first, in the same composite.
    ///
    /// The caret does NOT advance: simultaneity is the normal case on a drum staff, so an advancing caret would
    /// mis-fire on every stacked hit and force a step back. Stepping stays explicit, on ← / →.
    public func pressDrumKey(_ key: DrumPadKey) {
        guard let score, let column = caretColumn, isDrumStaffActive else { return }

        var members: [EditIntent] = []
        if instrument(on: column.staff)?.drumset[key.pitch] == nil {
            members.append(.setDrumsetEntry(
                partIndex: column.staff.partIndex,
                pitch: key.pitch,
                entry: GMDrumset.entry(forPitch: key.pitch, line: key.line),
            ))
        }
        var slotIndexShift = 0
        if ColumnNavigation.slot(inVoice: key.voiceIndex, at: column, in: score) == nil {
            members.append(.createVoice(
                staff: column.staff, measureIndex: column.measureIndex, voiceIndex: key.voiceIndex,
            ))
        }
        // A voice that is about to be created holds one measure rest, so the column lands inside it at its own
        // tick — the same shape as any other mid-rest landing, and handled by the same split below.
        let covering = ColumnNavigation.slot(inVoice: key.voiceIndex, at: column, in: score)
        let slot = covering?.slot ?? VoiceElementID(
            staff: column.staff, measureIndex: column.measureIndex, voiceIndex: key.voiceIndex, elementIndex: 0,
        )
        let tickWithinSlot = covering?.tickWithinSlot ?? column.tick
        if tickWithinSlot != 0 {
            members.append(.splitRest(at: slot, tickOffset: tickWithinSlot))
            // The write targets the head of the run the split's TAIL becomes, and the composite is planned against
            // the pre-split score — so the index is computed rather than re-read, from ssm's own decomposition,
            // the very one `SplitRest` uses. The two cannot disagree.
            slotIndexShift = DurationChangeAlgorithm.alignedDurations(
                forTicks: tickWithinSlot, rtickStart: column.tick - tickWithinSlot, division: score.division,
            ).count
        }
        let target = VoiceElementID(
            staff: slot.staff, measureIndex: slot.measureIndex, voiceIndex: slot.voiceIndex,
            elementIndex: slot.elementIndex + slotIndexShift,
        )
        members.append(contentsOf: writeMembers(for: key, at: target, tickWithinSlot: tickWithinSlot, in: score))
        guard !members.isEmpty else { return }

        let revisionBeforePress = revision
        guard apply(members.count == 1 ? members[0] : .composite(members)) != nil else { return }
        landOnDrumWrite(at: target, unlessStillAt: revisionBeforePress)
    }

    /// The intents that put `key`'s instrument into (or take it out of) the slot at `target`.
    ///
    /// `tickWithinSlot` is what the caller measured BEFORE any split: non-zero means the slot it names does not
    /// exist yet, so the branch has to be the rest one — there is nothing there to inspect.
    private func writeMembers(
        for key: DrumPadKey, at target: VoiceElementID, tickWithinSlot: Int, in score: Score,
    ) -> [EditIntent] {
        guard tickWithinSlot == 0, case let .chord(chord)? = score[target] else {
            return inputMembers(for: key, at: target)
        }
        if let noteIndex = chord.notes.firstIndex(where: { $0.pitch == key.pitch }) {
            let note = NoteID(
                staff: target.staff, measureIndex: target.measureIndex, voiceIndex: target.voiceIndex,
                elementIndex: target.elementIndex, noteIndexInChord: noteIndex,
            )
            return [.removeNoteFromChord(at: note)]
        }
        guard !chord.notes.isEmpty else { return inputMembers(for: key, at: target) }
        return [
            .addNoteToChord(at: target, pitch: key.pitch, tpc: Self.drumTPC, accidental: nil),
            .setNoteHead(
                at: NoteID(
                    staff: target.staff, measureIndex: target.measureIndex, voiceIndex: target.voiceIndex,
                    elementIndex: target.elementIndex, noteIndexInChord: chord.notes.count,
                ),
                headType: key.headType,
            ),
        ]
    }

    /// Writing into a rest slot: the note at the armed length, then its head.
    private func inputMembers(for key: DrumPadKey, at target: VoiceElementID) -> [EditIntent] {
        [
            .inputNote(
                at: RestID(
                    staff: target.staff, measureIndex: target.measureIndex,
                    voiceIndex: target.voiceIndex, elementIndex: target.elementIndex,
                ),
                pitch: key.pitch, tpc: Self.drumTPC, duration: armedInputDuration,
            ),
            .setNoteHead(
                at: NoteID(
                    staff: target.staff, measureIndex: target.measureIndex, voiceIndex: target.voiceIndex,
                    elementIndex: target.elementIndex, noteIndexInChord: 0,
                ),
                headType: key.headType,
            ),
        ]
    }

    /// Leaves the selection on the note just toggled on, so the callout still covers duration and ties for it, and
    /// leaves the CARET where it was: the column does not advance on a drum staff.
    private func landOnDrumWrite(at target: VoiceElementID, unlessStillAt previousRevision: Int) {
        guard revision != previousRevision, let score else { return }
        let written = SelectionRederivation.item(at: target, in: score, preferringNoteIndex: nil)
        let column = caretColumn
        place(selection: written, caret: caretItem)
        caretColumn = column
    }

    // MARK: - Reading the staff

    private func instrument(on staff: StaffAddress) -> Instrument? {
        guard let score, score.parts.indices.contains(staff.partIndex) else { return nil }
        return score.parts[staff.partIndex].instrument
    }

    private func voiceIndices(at column: ScoreColumn, in score: Score) -> Range<Int> {
        guard score.parts.indices.contains(column.staff.partIndex),
              score.parts[column.staff.partIndex].staves.indices.contains(column.staff.staffIndexInPart)
        else { return 0 ..< 0 }
        let measures = score.parts[column.staff.partIndex].staves[column.staff.staffIndexInPart].measures
        guard measures.indices.contains(column.measureIndex) else { return 0 ..< 0 }
        return measures[column.measureIndex].voices.indices
    }

    /// The tonal pitch class a drum note carries. A percussion pitch is a kit position, not a spelling — nothing
    /// reads a drum note's tpc — so every drum note takes the same neutral value rather than pretending to a key.
    static var drumTPC: Int {
        14
    }
}
