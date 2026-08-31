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
    /// `name` and `instrumentName` are deliberately two things. A part called "なおき" is still a piano, and a
    /// score written that way clones as five differently-named piano parts — the list has to be able to say what
    /// each row *is* as well as what it is called.
    struct PartDraft: Equatable, Identifiable {
        /// List identity for `ForEach` / `onMove`. Deliberately not derived from the instrument id — a string
        /// quartet holds two rows with the same instrument, and dragging them apart needs them distinguishable.
        let id: UUID
        /// The part's name, as the user has it: the localized catalog name for a catalog pick, the part's own
        /// name for a cloned one, and whatever they type over it afterwards. Empty means "named after its
        /// instrument" — see `resolvedName`.
        var name: String
        /// The short (staff-label) name — `ScoreInstrument.englishAbbreviation` for a catalog pick, the source
        /// part's own `shortName` for a cloned one.
        ///
        /// Only `nil` when cloning a part that carries no abbreviation. It is worth setting wherever we can:
        /// the layout engine labels systems 2+ with `shortName ?? ""`, so a part without one engraves an
        /// unlabeled staff on every system after the first.
        var shortName: String?
        /// What this row *is*, named in the reader's language. `nil` only for a cloned part whose instrument id
        /// this build's catalog does not know and whose source score carried no track name to fall back on.
        let instrumentName: String?
        /// The part this row builds. Its `longName` / `shortName` are seeded here but are not authoritative —
        /// `resolvedPlan()` writes the row's current names in, so an edited name cannot fall out of step.
        var plan: BlankScoreTemplate.PartPlan

        /// The name this row builds under: what the user typed, or the instrument's own name when they left the
        /// field empty. Only ever the raw instrument id in the one case that has neither.
        var resolvedName: String {
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? (instrumentName ?? plan.instrumentID) : trimmed
        }

        /// The plan to build, with this row's current names written in.
        func resolvedPlan() -> BlankScoreTemplate.PartPlan {
            var plan = plan
            plan.longName = resolvedName
            plan.shortName = shortName
            return plan
        }

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
                id: UUID(), name: name, shortName: abbreviation,
                instrumentName: name, plan: plan,
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
        ///
        /// The part's *name* and its *instrument* are read from different places, because in a renamed score they
        /// are different things. MuseScore engraves `Instrument.longName` at the staff — that is where a part
        /// called "なおき" lives — while the instrument it plays is `Instrument.id` ("piano"), which the ScoreUI
        /// catalog turns back into a name in the reader's language. `Part.trackName` is the fallback for an id
        /// the catalog does not know: MuseScore stores the instrument's own name there ("ピアノ"), untouched by
        /// the rename.
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
                id: UUID(), name: name, shortName: instrument.shortName,
                instrumentName: instrumentDisplayName(of: part), plan: plan,
            )
        }
    }

    /// The template a fresh form opens on — the same solo piano the M1 form defaulted to.
    static let defaultTemplateID = "solo-piano"

    /// `instrumentationSource` for a list the user built or edited by hand, and for one cloned from another score.
    /// Analytics vocabulary, not ids: they sit in the same `score_created.template` parameter as a template id, so a
    /// query can ask "which ensembles do people start from" in one group-by.
    static let customSource = "custom"
    static let clonedSource = "cloned"

    var title = ""
    var composer = ""

    /// The parts to create, in score order. Every structural write — a wholesale assignment, an `append`, an
    /// `onMove` — drops `bracketGroups` and demotes the provenance stamp, so no caller can edit the list and
    /// forget to invalidate the grouping. `applyTemplate` is the one flow that keeps a grouping, and it assigns
    /// `bracketGroups` *after* the list for exactly that reason.
    ///
    /// Gated on the list's *structure* actually changing — the drafts' ids in order. Renaming a part is a write
    /// to this array too (the list's fields bind through it), and a rename changes neither which instruments the
    /// ensemble holds nor how they are bracketed.
    var instrumentation: [PartDraft] = NewScoreForm.seedInstrumentation() {
        didSet {
            guard instrumentation.map(\.id) != oldValue.map(\.id) else { return }
            bracketGroups = []
            instrumentationSource = Self.customSource
        }
    }

    /// Where the current list came from, for `score_created.template`: a template's id, `clonedSource`, or
    /// `customSource`. Maintained exactly like `bracketGroups` — every structural edit demotes it to "custom", and the
    /// two seeding flows stamp their own value *after* assigning the list, for the same reason.
    ///
    /// A fresh form opens on `defaultTemplateID` because that is what `seedInstrumentation()` puts in the list; that
    /// assignment does not go through the setter above, so it is not a hand-edit.
    private(set) var instrumentationSource = NewScoreForm.defaultTemplateID

    /// Half-open part ranges a group bracket spans. Set by `applyTemplate` (from the template's own grouping) and by
    /// `applyInstrumentation(of:)` (derived from the source score's brackets); cleared by every manual edit — a
    /// hand-edited ensemble no longer matches the grouping it was seeded with. Grand-staff braces are per-part
    /// (`Part.init(blankPlan:id:measures:)` adds them) and are unaffected by this.
    var bracketGroups: [Range<Int>] = []
    var concertKey = 0
    // Two Ints, not a tuple: Equatable synthesis rejects tuple stored properties.
    var timeNumerator = 4
    var timeDenominator = 4

    /// Backing storage for `pickup`. Written only through the property below, and never read directly — the
    /// stored value can be one the current meter does not offer.
    private var chosenPickup: Fraction?

    /// The opening bar's own length when the score starts on an anacrusis, `nil` (the default) when it does not.
    /// Always a fraction `isPickupAvailable` accepts for the current meter, or `nil`.
    ///
    /// The invariant is enforced on READ rather than by clearing the stored value when the meter changes, and
    /// the distinction is load-bearing: the two meter fields are written one at a time, so any check that ran
    /// on assignment would judge the pickup against a meter that pairs one field's new value with the other's
    /// old one. `TimeSignaturePicker`'s preset chips do exactly that — jumping from 7/8 to 3/4 sets the
    /// numerator first, and a clear-on-write check saw the transient 3/8, where a 5/8 pickup does not fit,
    /// destroying a pickup that 3/4 accommodates perfectly well.
    ///
    /// Validating on read makes that transient invisible, and gives the user the better behavior besides: a
    /// meter passed through on the way to another one costs them nothing. The pickup stops being offered while
    /// it does not fit and comes back if the meter does.
    var pickup: Fraction? {
        get {
            guard let chosenPickup,
                  Self.isPickupAvailable(chosenPickup, numerator: timeNumerator, denominator: timeDenominator)
            else { return nil }
            return chosenPickup
        }
        set { chosenPickup = newValue }
    }

    var tempoBPM = 120
    /// Total bars INCLUDING the pickup, matching `BlankScoreTemplate.measureCount` — a 32-bar score with a
    /// pickup is the pickup plus 31 full bars.
    var measureCount = 32

    // MARK: - Instrumentation edits

    /// Replaces the list with `template`'s expansion and adopts its bracket grouping. The assignment order is
    /// load-bearing: setting `instrumentation` clears `bracketGroups`, so the template's grouping goes on after.
    mutating func applyTemplate(_ template: ScoreCreationTemplate) {
        instrumentation = template.instruments.map(PartDraft.fromCatalog)
        bracketGroups = template.bracketGroups
        instrumentationSource = template.id
    }

    /// Replaces the list with `score`'s parts, cloned structure-first, and adopts the grouping its cross-part
    /// brackets describe (`partBracketGroups(of:)`). Same assignment order as `applyTemplate`, for the same reason:
    /// setting `instrumentation` clears `bracketGroups` and demotes the provenance stamp, so both go on afterwards.
    mutating func applyInstrumentation(of score: Score) {
        instrumentation = score.parts.enumerated().map { index, part in
            PartDraft.fromExistingPart(part, at: index, in: score)
        }
        bracketGroups = Self.partBracketGroups(of: score)
        instrumentationSource = Self.clonedSource
    }

    /// `score`'s cross-part group brackets as the half-open PART ranges `BlankScoreTemplate.bracketGroups` speaks.
    ///
    /// A `BracketItem` is anchored on a `Staff` and its `span` counts staves in the GLOBAL flattened staff order (the
    /// convention `Score.filtered(hidingStaves:)` documents and `Score.blank`'s `applyBracketGroups` writes), so the
    /// anchor staff's global index and the span give the staff interval the bracket covers; the parts contributing
    /// staves to that interval are the group.
    ///
    /// Three deliberate reductions:
    ///
    /// * **`.brace` is skipped.** A brace is per-part — a grand staff's own — and `Part.init(blankPlan:id:measures:)`
    ///   re-derives one for every multi-staff part it builds. Cloning it as a group would draw a second bracket
    ///   around a part that already braces itself.
    /// * **Every other type clones as `.normal`.** `bracketGroups` is a bare list of part ranges with no style, and
    ///   `Score.blank` engraves `.normal` for each, so a `.square` or `.line` group in the source comes back as a
    ///   normal bracket. That is the whole vocabulary the template has.
    /// * **A span ending part-way through a part EXPANDS to that whole part.** A part range cannot describe "one
    ///   staff of a grand staff", and expanding keeps the bracket over everything the user saw it over — the
    ///   alternative, dropping it, loses the grouping entirely.
    ///
    /// Duplicate ranges (two brackets resolving to the same parts) collapse to one, in first-seen order.
    static func partBracketGroups(of score: Score) -> [Range<Int>] {
        // Flattened staff order → owning part index, so a bracket's global span maps straight back to parts.
        var partOfGlobalStaff: [Int] = []
        var globalStartOfPart: [Int] = []
        for (partIndex, part) in score.parts.enumerated() {
            globalStartOfPart.append(partOfGlobalStaff.count)
            partOfGlobalStaff.append(contentsOf: repeatElement(partIndex, count: part.staves.count))
        }
        var groups: [Range<Int>] = []
        for (partIndex, part) in score.parts.enumerated() {
            for (staffIndex, staff) in part.staves.enumerated() {
                for bracket in staff.brackets where bracket.type != .brace && bracket.type != .noBracket {
                    let first = globalStartOfPart[partIndex] + staffIndex
                    // Clamp: a score can declare a span running past its last staff, and MuseScore draws what exists.
                    let last = min(first + bracket.span - 1, partOfGlobalStaff.count - 1)
                    guard partOfGlobalStaff.indices.contains(first), first <= last else { continue }
                    let group = partOfGlobalStaff[first] ..< (partOfGlobalStaff[last] + 1)
                    if !groups.contains(group) {
                        groups.append(group)
                    }
                }
            }
        }
        return groups
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
            parts: instrumentation.map { $0.resolvedPlan() },
            bracketGroups: bracketGroups,
            concertKey: concertKey,
            timeNumerator: timeNumerator,
            timeDenominator: timeDenominator,
            tempoBPM: Double(tempoBPM),
            measureCount: measureCount,
            pickup: pickup,
        )
    }

    // MARK: - Pickup

    /// The note values a pickup can be written over in a meter, coarsest first — the denominator half of the
    /// pickup row's two menus.
    ///
    /// A note value survives only if *some* pickup fits under a full bar in it: 4/4 has no whole-note pickup,
    /// because an opening bar as long as the meter is simply a full bar. Which values are admissible at all is
    /// `isPickupAvailable`'s rule — an eighth note, or the meter's own denominator when that is finer, so 3/16
    /// can start on a sixteenth while 3/4 offers eighths rather than the sixteenths nobody starts a piece on.
    static func pickupDenominators(numerator: Int, denominator: Int) -> [Int] {
        FractionMenuRow.noteValues.filter { candidate in
            isPickupAvailable(
                Fraction(numerator: 1, denominator: candidate),
                numerator: numerator, denominator: denominator,
            )
        }
    }

    /// The beat counts a pickup can take over `pickupDenominator` in a meter — the numerator half of the row's
    /// two menus, and empty for a note value the meter does not admit at all.
    ///
    /// `isPickupAvailable(_:numerator:denominator:)` decides the same question one value at a time; the two are
    /// held in step by `pickup availability agrees with the offered menus` in `NewScoreTests`.
    static func pickupNumerators(over pickupDenominator: Int, numerator: Int, denominator: Int) -> [Int] {
        guard numerator > 0, denominator > 0, pickupDenominator > 0 else { return [] }
        var counts: [Int] = []
        for count in 1 ... (numerator * pickupDenominator) {
            // count/pickupDenominator < numerator/denominator, cross-multiplied to stay in integers.
            guard count * denominator < numerator * pickupDenominator else { break }
            counts.append(count)
        }
        // A count is only offerable if the reduced fraction it makes is one the meter admits: 1/3 of a bar
        // reduces to something whose denominator does not divide the beat unit.
        return counts.filter { count in
            isPickupAvailable(
                Fraction(numerator: count, denominator: pickupDenominator),
                numerator: numerator, denominator: denominator,
            )
        }
    }

    /// Whether a meter offers `pickup` — the single rule the two menu vocabularies above are built out of, and
    /// the one the `pickup` property asks on every read: a fraction is a multiple of the beat unit exactly when
    /// its (reduced) denominator divides the unit, and it is a pickup only while it is shorter than a full bar.
    ///
    /// Membership, not just a length comparison: a meter change can coarsen the unit as well as shorten the bar,
    /// and 3/16's sixteenth-note pickup has no place in 3/4 either.
    static func isPickupAvailable(_ pickup: Fraction, numerator: Int, denominator: Int) -> Bool {
        guard numerator > 0, denominator > 0, pickup.numerator > 0 else { return false }
        let unit = max(8, denominator)
        guard unit % pickup.denominator == 0 else { return false }
        // pickup < numerator/denominator, cross-multiplied so the comparison stays in integers.
        return pickup.numerator * denominator < numerator * pickup.denominator
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
