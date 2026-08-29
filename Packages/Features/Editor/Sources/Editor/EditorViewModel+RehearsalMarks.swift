import Domain
import Foundation
import SheetMusicCore

/// Rehearsal-mark editing as the sheet drives it. Both writes route through the shared `apply(_:)` choke point, so
/// both are undoable and both re-publish the score to the reading surface for free.
///
/// Both address `targetMeasureIndex` — the selection's bar, else the caret's — and are a no-op without one, exactly
/// as the measure and signature ops next door are.
///
/// **No refusal surface, deliberately.** ssm can refuse these two with `.targetNotFound` (an out-of-range bar, which
/// a selection cannot produce) or `.emptyRehearsalMarkText` (which the sheet's disabled Apply button prevents), so
/// there is no reachable refusal for a `lastRehearsalMarkRefusal` to carry. A `false` here means the score already
/// said this — the `.nothingToApply` the session reports for restating a mark's own text, or for removing one from a
/// bar that carries none — and the sheet simply closes on it.
extension EditorViewModel {
    // MARK: - What the sheet opens showing

    /// The rehearsal mark on the target bar, or `nil` when it carries none (and without a target).
    ///
    /// Walks `Score.systemMeasures` directly: a rehearsal mark is a system element rather than a voice element, and
    /// ssm's own `RehearsalMarkLane` is internal to the engine — mirrored here the way `keySignatureReferenceStaff`
    /// mirrors `KeySignatureStaves`.
    var targetRehearsalMarkText: String? {
        guard let score, let targetMeasureIndex else { return nil }
        return Self.rehearsalMarkText(in: score, measureIndex: targetMeasureIndex)
    }

    /// What the sheet's field opens holding: the target bar's own mark when it has one (the sheet is renaming), and
    /// otherwise the next letter — the letter for however many bars strictly before this one carry a rehearsal mark,
    /// so a mark added between A and B is suggested "B" while B itself keeps its name.
    ///
    /// A suggestion, not a rule: the field is free-form, and nothing renumbers anything afterwards.
    ///
    /// A mark whose text is blank falls through to the letter rather than seeding the field with it: the engine's
    /// MSCX decoder reads a `<RehearsalMark>` with no `<text>` child as `text == ""`, so an imported score can carry
    /// one, and opening the sheet on an empty field would be worse than useless. `targetRehearsalMarkText` still
    /// reports the blank mark, which is what keeps the sheet's Delete row available to take it back out.
    var suggestedRehearsalMarkText: String {
        if let existing = targetRehearsalMarkText,
           !existing.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            return existing
        }
        guard let score, let targetMeasureIndex else { return Self.rehearsalMarkLetter(at: 0) }
        let earlier = (0 ..< min(targetMeasureIndex, score.systemMeasures.count)).count {
            Self.rehearsalMarkText(in: score, measureIndex: $0) != nil
        }
        return Self.rehearsalMarkLetter(at: earlier)
    }

    /// A, B, … Z, AA, AB, … — spreadsheet-column lettering, which is what a score does once it runs past Z.
    static func rehearsalMarkLetter(at index: Int) -> String {
        guard index >= 0 else { return "A" }
        var remaining = index
        var letters = ""
        repeat {
            letters = String(UnicodeScalar(UInt8(65 + remaining % 26))) + letters
            remaining = remaining / 26 - 1
        } while remaining >= 0
        return letters
    }

    // MARK: - Applying

    /// Writes `text` as the target bar's rehearsal mark, replacing the one it carries or creating one where it
    /// carried none. `false` when there is no target, or when the bar already reads exactly this.
    ///
    /// Reports `"set"` for a bar that carried no mark and `"rename"` for one that did — read BEFORE the apply,
    /// because the apply is what makes the bar carry one.
    @discardableResult
    func setRehearsalMark(text: String) -> Bool {
        guard let targetMeasureIndex else { return false }
        let action = targetRehearsalMarkText == nil ? "set" : "rename"
        return applyRehearsalMark(
            .setRehearsalMark(measureIndex: targetMeasureIndex, text: text), action: action,
        )
    }

    /// Drops the target bar's rehearsal mark. `false` when there is no target, or when the bar carries none.
    @discardableResult
    func removeRehearsalMark() -> Bool {
        guard let targetMeasureIndex else { return false }
        return applyRehearsalMark(.removeRehearsalMark(measureIndex: targetMeasureIndex), action: "remove")
    }

    private func applyRehearsalMark(_ intent: EditIntent, action: String) -> Bool {
        guard apply(intent) != nil else { return false }
        onRehearsalMarkEdited?(action)
        return true
    }

    // MARK: - Reading the score

    /// The first rehearsal mark's text at `measureIndex`, or `nil`. First rather than all: one bar carries one mark
    /// as far as this surface is concerned, which is the same premise ssm's own commands are written on.
    private static func rehearsalMarkText(in score: Score, measureIndex: Int) -> String? {
        guard score.systemMeasures.indices.contains(measureIndex) else { return nil }
        for positioned in score.systemMeasures[measureIndex].elements {
            if case let .rehearsalMark(mark) = positioned.element {
                return mark.text
            }
        }
        return nil
    }
}
