import Domain
import Foundation

/// The decoded `{ drawings, textBoxes }` an annotation payload carries. The persisted body, not the `AnnotationLayer`
/// domain type: the layer's `id` / `updatedAt` live in their own columns and the migration has no business minting
/// them. Held here rather than in Domain because only this one caller decodes a payload to rewrite it.
struct AnnotationLayerBody: Equatable {
    var drawings: [DrawingAnchor]
    var textBoxes: [TextBoxAnchor]

    var isEmpty: Bool {
        drawings.isEmpty && textBoxes.isEmpty
    }

    /// This body with every anchor's part index rewritten through `mapping` — see `AnnotationLayers.remappingParts`.
    func remapped(_ mapping: [Int: Int?]) -> AnnotationLayerBody {
        AnnotationLayerBody(
            drawings: AnnotationLayers.remappingParts(mapping, in: drawings),
            textBoxes: AnnotationLayers.remappingParts(mapping, in: textBoxes),
        )
    }
}

// MARK: - Part-index migration

extension EditorViewModel {
    /// Rewrites everything this device stores ABOUT the score by part index — the per-score `ReaderPreferences` row
    /// and the annotation layer's per-stroke anchors — so they still name the same parts after this session's
    /// add / remove / reorder. Returns the map it wrote through, or `nil` when it wrote nothing (the edit renumbered
    /// nothing, or a write failed).
    ///
    /// Runs here — inside `performSave`, right after the score itself is on disk — because that is the closest the
    /// two ever are: the file has just been given the new part order, so a row migrated now describes the file that
    /// was written. `ScoreEditSession` accumulates the map since the last consume point, so a save that lands three
    /// part operations later still gets one map from the state the row was last written in, and undo / redo need no
    /// special handling (the map is derived by diffing `Part.id`s, so an undone removal simply maps back to itself).
    ///
    /// **The score can move under the awaits, and that is accounted for rather than prevented.** `performSave` writes
    /// the score it pinned at entry, and by the time this runs the user may have applied further part edits to the
    /// live session — so what the map describes can already be ahead of what the file holds. The map and the baseline
    /// at least move together: consuming re-baselines to the session's CURRENT parts, so the row is put into the
    /// numbering the session is in, and it is the NEXT save that writes the matching file.
    ///
    /// That next save is only guaranteed because `performSave` refuses to clear `isDirty` when `mutationTicket` moved
    /// while it was suspended (see there). It is worth being precise about this: clearing it unconditionally was a
    /// bug, not a subtlety — the edit that arrived in the awaits would have been declared saved, so the row would
    /// have been migrated onto a part order the file was never given and nothing would ever have written it.
    ///
    /// What is NOT covered is a crash inside that window: the row would then describe a part order the file on disk
    /// never received. Closing that needs the row and the file to be written in one transaction, which this layering
    /// cannot express — it is the known cost of the two-writer arrangement.
    ///
    /// The mapping is consumed ONLY after BOTH writes succeed. A failure leaves it accumulating so the next save (or
    /// `endSession`'s retry) attempts the same migration; consuming first would re-baseline over state that never
    /// moved and leave it permanently pointing at the old numbering.
    ///
    /// **One map, one consume, two stores — so the two halves have to settle together.** Half-migrating and consuming
    /// anyway strands the other half; half-migrating and NOT consuming is worse, because the retry would rewrite the
    /// half that already moved a second time and point every setting at a third part. So the ink is written second and
    /// a failure there ROLLS THE ROW BACK to the value it was read at, leaving the retry a clean whole. Only a second
    /// failure — on the rollback write itself — can leave the two disagreeing. That residual is not expressible at
    /// THIS layer, but it is not unclosable: both stores are the same GRDB pool, so a combined Infrastructure write
    /// spanning the two tables would close it.
    ///
    /// Nothing stored (no row, no ink) still consumes: there is nothing to migrate, and leaving the map unconsumed
    /// would make the next part operation report a stale cumulative map against state written since. It reports `nil`
    /// then — nothing was written, so the host has nothing to re-read.
    @discardableResult
    func migratePartIndexedState(in session: ScoreEditSession, for id: ScoreItemID) async -> [Int: Int?]? {
        guard !session.isPartMappingIdentity else { return nil }
        return await migratePartIndexedState(session.partIndexMapping, in: session, for: id)
    }

    /// The same migration against an EXPLICIT map, for the one caller whose destination is not the session's current
    /// parts: `unwindSessionEdits`'s snapshot gear, which is about to restore a different score entirely.
    ///
    /// Consuming still re-baselines onto the session's current parts, which is correct even there — the session is
    /// thrown away immediately afterwards, and the replacement baselines on the restored score, which is exactly the
    /// numbering `mapping` has just put the row into.
    @discardableResult
    func migratePartIndexedState(
        _ mapping: [Int: Int?], in session: ScoreEditSession, for id: ScoreItemID,
    ) async -> [Int: Int?]? {
        // Ahead of BOTH reads, and here rather than at the one caller that raises the hold: all three migration sites
        // — the part op's own commit, `endSession`'s retry and `unwindSessionEdits`' snapshot gear — read the host's
        // stores, and the last two run with the host's debounced ink writer live and never drained. A capture pending
        // when either of those reads would land on the far side of the write and put the whole layer back into the
        // old numbering, with the mapping consumed. Draining at the one place the reads actually happen covers all
        // three by construction; a second drain from the commit path would only have been a no-op anyway (`flush`
        // does nothing once `pending` is clear).
        await onPartMigrationWillRun()
        do {
            // Both reads first: a read that throws must leave the stores exactly as they were, so there is nothing to
            // undo and the retry is a clean whole.
            let storedPreferences = try await repository.loadReaderPreferences(for: id)
            let storedInk = try await loadAnnotationLayerBody(for: id)
            if let storedPreferences {
                try await repository.saveReaderPreferences(storedPreferences.remappingParts(mapping))
            }
            // Only when the rewrite actually moved something. An item whose ink is all page-anchored (a PDF's original
            // rendition) is untouched by a part operation, and rewriting it anyway would bump `updated_at` — and with
            // it the sync's idea of what changed — on every instrument added.
            let migratedInk = storedInk.map { $0.remapped(mapping) }
            if let storedInk, let migratedInk, migratedInk != storedInk {
                do {
                    try await saveAnnotationLayerBody(migratedInk, for: id)
                } catch {
                    // Put the row back where it was read: see the failure policy above.
                    if let storedPreferences {
                        try? await repository.saveReaderPreferences(storedPreferences)
                    }
                    throw error
                }
            }
            session.consumePartIndexMapping()
            // `nil` only when there was nothing at all to migrate — either half having moved is something the host
            // has to re-read.
            return storedPreferences == nil && storedInk == nil ? nil : mapping
        } catch {
            // Leave the mapping unconsumed: the next save retries the migration with the same cumulative map.
            return nil
        }
    }

    /// The layer's decoded body, or `nil` when the score has no ink — which INCLUDES a payload that will not decode.
    /// An unreadable blob is not an I/O failure and no retry fixes it; the Reader's own loader already treats it as no
    /// ink, and blocking the mapping on it would strand the preferences row in the old numbering for good. Only a
    /// genuine store failure throws, and that one is worth retrying.
    private func loadAnnotationLayerBody(for id: ScoreItemID) async throws -> AnnotationLayerBody? {
        guard let annotationStore, let data = try await annotationStore.load(scoreID: id) else { return nil }
        guard let decoded = AnnotationLayerCodec.decode(data) else { return nil }
        return AnnotationLayerBody(drawings: decoded.drawings, textBoxes: decoded.textBoxes)
    }

    /// Writes the migrated body back — or DELETES the layer when the migration emptied it, the same empty→delete
    /// policy `AnnotationSaveCoordinator` applies on the Reader side (a score whose only inked part was removed must
    /// not be left holding an empty layer that reads as "annotated").
    private func saveAnnotationLayerBody(_ body: AnnotationLayerBody, for id: ScoreItemID) async throws {
        guard let annotationStore else { return }
        guard !body.isEmpty else {
            try await annotationStore.delete(scoreID: id)
            return
        }
        try await annotationStore.save(
            scoreID: id, updatedAt: Date(),
            payload: AnnotationLayerCodec.encode(drawings: body.drawings, textBoxes: body.textBoxes),
        )
    }

    /// Where each of `from`'s parts sits in `to`, by `Part.id`; `nil` = `to` does not have it. The same shape
    /// `ScoreEditSession.partIndexMapping` produces, computed between two scores the caller holds rather than
    /// against the session's own baseline.
    ///
    /// Duplicate ids on either side yield the identity map, for the reason `ScoreEditSession` documents: a
    /// `firstIndex(of:)` answer over duplicates is a plausible-looking lie, and moving one part's preferences onto
    /// another is worse than not migrating.
    static func partIndexMapping(from: Score, to: Score) -> [Int: Int?] {
        let source = from.parts.map(\.id)
        let destination = to.parts.map(\.id)
        guard Set(source).count == source.count, Set(destination).count == destination.count else {
            return Dictionary(uniqueKeysWithValues: source.indices.map { ($0, Optional($0)) })
        }
        return Dictionary(
            uniqueKeysWithValues: source.enumerated().map { ($0.offset, destination.firstIndex(of: $0.element)) },
        )
    }

    /// `first` followed by `second`, as one map. A key `first` sends to `nil` stays `nil`; so does one whose
    /// destination `second` does not know about.
    static func composing(_ first: [Int: Int?], _ second: [Int: Int?]) -> [Int: Int?] {
        first.mapValues { intermediate -> Int? in
            // Two unwraps, two different questions: did `first` keep this part, and does `second` know where the
            // index it landed on goes. Written as one `guard` because a `?? nil` reads as redundant and SwiftLint
            // strips it.
            guard let intermediate, let destination = second[intermediate] else { return nil }
            return destination
        }
    }
}
