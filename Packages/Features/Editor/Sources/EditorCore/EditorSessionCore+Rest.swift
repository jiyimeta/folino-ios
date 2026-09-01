import Domain
import SheetMusicCore

/// The pad's rest key, and the delete it grew out of.
///
/// Split from `EditorSessionCore+Input.swift` on the seam the key itself moved across: everything here is about a
/// slot BECOMING SILENT, while what stays there is about a slot taking a pitch. The two halves share the same
/// address — `writeTarget(in:)`'s caret column — and the same landing rule, `land(after:unlessStillAt:)`, which is
/// why both of those are internal rather than private.
extension EditorSessionCore {
    /// Deletes the SELECTION (the note you last wrote or tapped, not the slot the caret is parked on).
    /// Multi-note chord + `.note` selection → `.removeNoteFromChord`; single-note chord or whole-element selection →
    /// `.delete` (same-duration rest, measure length invariant), or a full-measure rest when that delete empties the
    /// measure (the engine's own full-measure-rest collapse); `.tuplet` selection → `.removeTuplet`. Selection stays
    /// on the affected slot (now a rest) via re-derivation.
    ///
    /// **No iOS key calls this.** The pad's ⌫ became the rest key, which says the same thing about a whole slot and
    /// says it at the caret; Android's bridge still forwards it. What the rest key cannot say is the one branch
    /// below that is not about a slot — **taking one notehead off a chord**. Reaching that today needs the caret on
    /// the chord with the chord's own length armed, so `writeRest`'s fallback runs; short of that, undo is the only
    /// way back out of a ＋音. The affordance it wants is a ⌫ in `EditorCalloutView`, shown only while the selection
    /// is a member of a multi-note chord — the rule the tie key already uses there — not a permanent delete key.
    public func deleteSelection() {
        guard let selectedItem, let score else { return }
        switch selectedItem {
        case let .note(noteID):
            guard case let .chord(chord)? = score[VoiceElementID(noteID)] else { return }
            if chord.notes.count > 1 {
                apply(.removeNoteFromChord(at: noteID))
            } else {
                deleteElement(at: VoiceElementID(noteID))
            }
        case let .rest(restID):
            deleteElement(at: VoiceElementID(restID))
        case let .tuplet(tupletID):
            removeTuplet(at: tupletID)
        case .clef:
            return
        }
    }

    /// The rest key. Writes a rest of the ARMED length into the slot the CARET marks — over a note, the note goes
    /// and that rest takes its place; over a rest already there, that rest is re-timed. Afterwards the selection
    /// sits on the rest that was written and the caret moves on, exactly as after a letter key.
    ///
    /// One rule for note and rest alike, because the key's own glyph is the armed length's rest and it promises the
    /// same thing whatever is underneath: "this slot becomes a rest of THIS length".
    ///
    /// **Addressed at the caret, not at the selection**, because a rest is a note without a pitch and this is a
    /// write key — the same class as C–B, and MuseScore's `0` is in that class too. It used to write at the
    /// selection: this key started life as ⌫ and kept ⌫'s addressing when it was reskinned into "write the armed
    /// length's rest". That made the most ordinary rhythm there is — ♩ then a ♩ rest — overwrite the note just
    /// typed, since input deliberately leaves the selection one slot behind the caret.
    ///
    /// Deleting does not go with it. Every path that NAMES a target — a tap, ← / → — places caret and selection
    /// together (`select(_:)`), so "tap a note, press the rest key" still turns that note into a rest, which is
    /// what deleting means in a score whose bars keep their length. The only case that moves is the one where the
    /// two markers are apart, and that is the case that was wrong.
    public func writeRest() {
        guard let score, let target = writeTarget(in: score), let score = self.score else { return }
        switch target {
        case .note, .rest:
            writeRest(over: target, in: score)
        case let .tuplet(tupletID):
            removeTuplet(at: tupletID)
        case .clef:
            return
        }
    }

    /// Writes a rest of the armed length over the timed slot `target` names, whatever is currently in it.
    ///
    /// The guard is the key's INTERPRETATION and stays here: with nothing armed, the armed length already in the
    /// slot, or a tuplet member (whose lengths are the tuplet's to decide), the key falls back to a plain delete on
    /// a note and writes nothing on a rest — exactly as before. Everything past the guard is planning, and
    /// `.writeRest` owns it now: the cross-barline run of rests, the `.measure` promotion for a bar-filling length,
    /// and the delete-plus-retime composite over a note (with the PLAIN delete — re-timing must not collapse the
    /// bar it empties, that would throw away the length the user just stated).
    ///
    /// **The caret advances even when nothing was written**, in the one sub-case where the slot already holds the
    /// rest that was asked for: the key was still a write, and its answer was "already so". Without that, tapping
    /// the rest key to skip over a bar of same-length rests parks the caret on the first one forever.
    ///
    /// The delete fallback does NOT advance. It is the one path whose edit can collapse the bar it empties into a
    /// single measure rest, which renumbers the elements after it — `location` would no longer name what it named,
    /// and the two markers belong wherever the collapse put them. `apply`'s own re-derivation places them there.
    private func writeRest(over target: SheetMusicCore.ScoreItemID, in score: Score) {
        guard let location = Self.slot(of: target), case let .chord(current)? = score[location] else { return }
        let revisionBeforeWrite = revision
        guard let armed = armedInputDuration, current.duration != armed, !isInsideTuplet(location) else {
            guard !current.notes.isEmpty else {
                land(after: location, unlessStillAt: nil)
                return
            }
            // The caret's own reading of "delete what is here", rather than `deleteSelection()`'s: with the two
            // markers apart during input the selection is a slot behind, and this key stopped speaking for it.
            if case let .note(noteID) = target, current.notes.count > 1 {
                apply(.removeNoteFromChord(at: noteID))
            } else {
                deleteElement(at: location)
            }
            return
        }
        guard apply(.writeRest(at: location, duration: armed)) != nil else { return }
        land(after: location, unlessStillAt: revisionBeforeWrite)
    }

    /// Whether the rest key has something to write into: the CARET on any timed slot, note or rest.
    ///
    /// Caret-based like the key itself. Read from the selection it went inert exactly when the next rest was about
    /// to be typed — during input the selection is the note behind the caret, and that is a valid target too, so
    /// the old answer was right by accident and only while the two markers agreed.
    public var canWriteRest: Bool {
        switch caretItem {
        case .note, .rest: true
        case .tuplet, .clef, .none: false
        }
    }

    private func removeTuplet(at tupletID: TupletID) {
        apply(.removeTuplet(at: VoiceElementID(
            staff: tupletID.staff,
            measureIndex: tupletID.measureIndex,
            voiceIndex: tupletID.voiceIndex,
            elementIndex: tupletID.startElementIndex,
        )))
    }

    /// `.delete`: a plain delete leaves a same-duration rest; a delete that empties its bar collapses the voice-
    /// measure to ONE measure rest (the engine's own full-measure-rest collapse), reporting the collapsed rest as
    /// the affected location — so re-derivation lands the selection there without the explicit `select` this method
    /// used to do.
    private func deleteElement(at location: VoiceElementID) {
        apply(.delete(at: location))
    }
}
