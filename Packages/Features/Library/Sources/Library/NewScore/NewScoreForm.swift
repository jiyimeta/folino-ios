import Domain
import Foundation
import ScoreUI

/// Everything the creation wizard collects. The instrumentation is a free list of parts rather than a fixed preset:
/// a template seeds it, the instrument catalog appends to it, an existing score can be cloned into it, and the user
/// can reorder or delete rows afterwards. `template()` maps the list, in order, onto `BlankScoreTemplate.parts`.
struct NewScoreForm: Equatable {
    /// One row of the wizard's instrumentation list — either a catalog pick or a part cloned from an existing
    /// score (which may name an instrument this build's catalog does not know).
    ///
    /// `baseName` is the un-numbered name the row was created with; `displayName` is that name with the
    /// duplicate suffix the enclosing list decides on ("Violin 1" / "Violin 2"). `plan` carries the same
    /// numbering into the built score, so what the wizard lists and what the parts are called agree.
    struct PartDraft: Equatable, Identifiable {
        /// List identity for `ForEach` / `onMove`. Deliberately not derived from the instrument id — a string
        /// quartet holds two rows with the same instrument, and dragging them apart needs them distinguishable.
        let id: UUID
        /// The name before duplicate numbering. The localized catalog name for a catalog pick, the part's own
        /// name for a cloned part.
        var baseName: String
        /// The short (staff-label) name before numbering — `ScoreInstrument.englishAbbreviation` for a catalog
        /// pick, the source part's own `shortName` for a cloned one.
        ///
        /// Only `nil` when cloning a part that carries no abbreviation. It is worth setting wherever we can:
        /// the layout engine labels systems 2+ with `shortName ?? ""`, so a part without one engraves an
        /// unlabeled staff on every system after the first.
        var baseShortName: String?
        /// `baseName` plus the numbering suffix, when the list holds more than one row with this base name.
        /// Maintained by `NewScoreForm.renumber()`; never assigned from outside.
        var displayName: String
        /// The part this row builds. `longName` / `shortName` are kept in step with `displayName`.
        var plan: BlankScoreTemplate.PartPlan

        /// A catalog instrument as a new row, named in the reader's language.
        static func fromCatalog(_ instrument: ScoreInstrument) -> PartDraft {
            let name = localizedInstrumentName(instrument)
            // English, deliberately, while `name` is localized: staff abbreviations are engraving conventions
            // ("Vln.", "Cl."), not prose, and every language folino ships uses the Latin-alphabet forms on the
            // page. `ScoreUI` has no abbreviation catalog to resolve them against, and inventing one is a
            // separate change — see the note in task-8-report.md.
            let abbreviation = instrument.englishAbbreviation
            var plan = instrument.partPlan()
            plan.longName = name
            plan.shortName = abbreviation
            return PartDraft(
                id: UUID(), baseName: name, baseShortName: abbreviation,
                displayName: name, plan: plan,
            )
        }

        /// A part of an existing score as a new row, copying its structure verbatim: per-staff opening clef,
        /// percussion-ness, transposition, GM program, drum kit and names.
        ///
        /// The clef comes from `Score.authoredClef(at:)` — the explicit measure-0 clef when the part has one,
        /// the staff's default otherwise — so a part whose staves were re-clefted after creation clones as it
        /// currently reads, not as it was authored. The score and part index are needed for exactly that: the
        /// authored clef is a score-level lookup, not a property of `Part`.
        ///
        /// The instrument need not be in the catalog: a score imported from another program keeps whatever
        /// instrument id and name it arrived with.
        static func fromExistingPart(_ part: Part, at partIndex: Int, in score: Score) -> PartDraft {
            let instrument = part.instrument
            let staves = part.staves.indices.map { staffIndex in
                let address = StaffAddress(partIndex: partIndex, staffIndexInPart: staffIndex)
                return BlankScoreTemplate.StaffPlan(
                    clefType: score.authoredClef(at: address)
                        ?? part.staves[staffIndex].defaultClefType
                        ?? "G",
                    isPercussion: part.staves[staffIndex].group == GMPercussion.staffGroup,
                )
            }
            let name = instrument.longName ?? part.trackName ?? instrument.id
            let plan = BlankScoreTemplate.PartPlan(
                instrumentID: instrument.id,
                longName: name,
                shortName: instrument.shortName,
                staves: staves,
                transposeDiatonic: instrument.transposeDiatonic,
                transposeChromatic: instrument.transposeChromatic,
                gmProgram: instrument.channel.program,
                isDrums: instrument.useDrumset,
            )
            return PartDraft(
                id: UUID(), baseName: name, baseShortName: instrument.shortName,
                displayName: name, plan: plan,
            )
        }
    }

    /// The key picker's menu: circle of fifths, C-major center. Raw value is `KeySignature.concertKey`.
    static let keyChoices: [Int] = [0, 1, 2, 3, 4, 5, 6, -1, -2, -3, -4, -5, -6]
    /// numerator/denominator pairs offered by the time picker.
    static let timeChoices: [(Int, Int)] = [(4, 4), (3, 4), (2, 4), (6, 8), (12, 8), (2, 2), (5, 4)]

    /// The template a fresh form opens on — the same solo piano the M1 form defaulted to.
    static let defaultTemplateID = "solo-piano"

    var title = ""
    var composer = ""

    /// Backing storage for `instrumentation`. Written directly (never through the computed property) by
    /// `renumber()`, which is what keeps the renumbering pass from re-entering itself.
    private var parts: [PartDraft] = NewScoreForm.seedInstrumentation()

    /// The parts to create, in score order. Every write — a wholesale assignment, an `append`, an `onMove` —
    /// renumbers duplicates and drops `bracketGroups`, so no caller can edit the list and forget to invalidate
    /// the grouping. `applyTemplate` is the one flow that keeps a grouping, and it assigns `bracketGroups`
    /// *after* the list for exactly that reason.
    ///
    /// The clearing is gated on the list's structure actually changing — the drafts' ids in order. Renumbering
    /// rewrites `displayName`/`plan` in place, and a rewrite alone must not count as an edit.
    ///
    /// Computed over `parts` rather than stored with a `didSet`: a `didSet` that calls a mutating method
    /// which writes back into the same property DOES re-enter the observer (only a direct assignment in the
    /// observer's own body is exempt), and the renumbering pass recursed until the stack ran out.
    var instrumentation: [PartDraft] {
        get { parts }
        set {
            let structureChanged = newValue.map(\.id) != parts.map(\.id)
            parts = newValue
            renumber()
            if structureChanged {
                bracketGroups = []
            }
        }
    }

    /// Half-open part ranges a group bracket spans. Set by `applyTemplate`; cleared by every manual edit — a
    /// hand-edited ensemble no longer matches the template's grouping. Grand-staff braces are per-part
    /// (`Part.init(blankPlan:id:measures:)` adds them) and are unaffected by this.
    var bracketGroups: [Range<Int>] = []
    var concertKey = 0
    // Two Ints, not a tuple: Equatable synthesis rejects tuple stored properties.
    var timeNumerator = 4
    var timeDenominator = 4
    var tempoBPM = 120
    var measureCount = 32

    // MARK: - Instrumentation edits

    /// Replaces the list with `template`'s expansion and adopts its bracket grouping. The assignment order is
    /// load-bearing: setting `instrumentation` clears `bracketGroups`, so the template's grouping goes on after.
    mutating func applyTemplate(_ template: ScoreCreationTemplate) {
        instrumentation = template.instruments.map(PartDraft.fromCatalog)
        bracketGroups = template.bracketGroups
    }

    /// Replaces the list with `score`'s parts, cloned structure-first. Brackets are NOT cloned: the source's
    /// grouping is expressed in global staff spans, which no longer describe this list once the user edits it.
    mutating func applyInstrumentation(of score: Score) {
        instrumentation = score.parts.enumerated().map { index, part in
            PartDraft.fromExistingPart(part, at: index, in: score)
        }
    }

    /// Replaces the whole list with a single catalog instrument — the "start from an instrument" entry point.
    mutating func replaceInstrumentation(with instrument: ScoreInstrument) {
        instrumentation = [.fromCatalog(instrument)]
    }

    mutating func addInstrument(_ instrument: ScoreInstrument) {
        instrumentation.append(.fromCatalog(instrument))
    }

    mutating func removeInstruments(at offsets: IndexSet) {
        instrumentation.remove(atOffsets: offsets)
    }

    mutating func moveInstruments(fromOffsets source: IndexSet, toOffset destination: Int) {
        instrumentation.move(fromOffsets: source, toOffset: destination)
    }

    // MARK: - Template

    /// `nil` while the form isn't submittable: an empty title (same rule as `EditableScoreInfo.normalized()`)
    /// or an instrumentation the user emptied out.
    func template() -> BlankScoreTemplate? {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty, !instrumentation.isEmpty else { return nil }
        let trimmedComposer = composer.trimmingCharacters(in: .whitespacesAndNewlines)
        return BlankScoreTemplate(
            title: trimmedTitle,
            composer: trimmedComposer.isEmpty ? nil : trimmedComposer,
            parts: instrumentation.map(\.plan),
            bracketGroups: bracketGroups,
            concertKey: concertKey,
            timeNumerator: timeNumerator,
            timeDenominator: timeDenominator,
            tempoBPM: Double(tempoBPM),
            measureCount: measureCount,
        )
    }

    // MARK: - Duplicate numbering

    /// Numbers rows that share a base name ("Violin 1" / "Violin 2") and un-numbers those that no longer do.
    ///
    /// Grouping is by base NAME, not by instrument id: two violins picked from the catalog share a name and want
    /// numbering, while two parts cloned from a score that already called them "Violin 1" and "Violin 2" do not —
    /// numbering by id would make those "Violin 1 1" and "Violin 2 1".
    ///
    /// The number rides into the built score as well, on `longName` and (when the row has one) `shortName`, so the
    /// part labels a user reads on the page match the wizard's list.
    ///
    /// Runs from `instrumentation`'s setter, which covers the mutating helpers above and a wholesale assignment
    /// alike. It writes to the `parts` storage rather than back through `instrumentation`, so it cannot re-enter
    /// the setter that called it.
    private mutating func renumber() {
        var counts: [String: Int] = [:]
        for draft in parts {
            counts[draft.baseName, default: 0] += 1
        }
        var seen: [String: Int] = [:]
        for index in parts.indices {
            let base = parts[index].baseName
            guard let total = counts[base], total > 1 else {
                parts[index].displayName = base
                parts[index].plan.longName = base
                parts[index].plan.shortName = parts[index].baseShortName
                continue
            }
            let ordinal = (seen[base] ?? 0) + 1
            seen[base] = ordinal
            let numbered = "\(base) \(ordinal)"
            parts[index].displayName = numbered
            parts[index].plan.longName = numbered
            parts[index].plan.shortName = parts[index].baseShortName.map { "\($0) \(ordinal)" }
        }
    }

    /// The list a fresh form opens on. A static function rather than a stored default so it is evaluated per
    /// form — the drafts carry `UUID` identities that must not be shared between two forms.
    private static func seedInstrumentation() -> [PartDraft] {
        guard let template = ScoreCreationTemplate.all.first(where: { $0.id == defaultTemplateID }) else {
            return []
        }
        return template.instruments.map(PartDraft.fromCatalog)
    }
}

/// Wraps whatever `ScoreFileCreator.createScore` throws so `LibraryViewModel.createScore(from:)` can surface a
/// creation-specific message through the shared `currentError`/`ImportErrorAlert` channel instead of the (accurate
/// but import-flavored) wording `describeLibraryError` picks for the same underlying `DomainError` case.
struct ScoreCreationFailed: LocalizedError {
    var errorDescription: String? {
        String(localized: "library.newScore.error", bundle: .module)
    }
}
