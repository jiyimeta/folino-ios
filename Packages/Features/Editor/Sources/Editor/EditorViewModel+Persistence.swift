import Domain
import Foundation

// MARK: - Autosave (Task 10)

extension EditorViewModel {
    /// Debounced 2 s after the last mutation; cancelled+rescheduled on each. Mirrors the Reader's annotation
    /// debounce pattern (ReaderViewModel+AnnotationPersistence.swift:17-34).
    func scheduleAutosave() {
        autosaveTask?.cancel()
        autosaveTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            if Task.isCancelled { return }
            await self?.runSave()
        }
    }

    /// Cancel the debounce and write now. Safe when nothing is pending. Called by endSession and (Task 15) on
    /// scene-background.
    public func flushPendingSave() async {
        autosaveTask?.cancel()
        autosaveTask = nil
        await runSave()
    }

    /// Wraps `performSave()` in a tracked `Task`, from either trigger site, so `revertToOriginal()` can await
    /// whatever save is already running before it does anything to the file itself (Critical 2 review fix):
    /// cancelling `autosaveTask` does not reach a call already past `performSave()`'s entry guard.
    ///
    /// Chained onto the PREVIOUS `inFlightSaveTask`, not just overwriting it: without the chain, a `runSave()`
    /// starting while an earlier one is still suspended in `captureOriginalIfNeeded` would drop that earlier
    /// handle, and `revertToOriginal()` — which only ever reads the latest one — would join just the newer call.
    /// Chaining keeps `inFlightSaveTask` at any moment a handle whose completion implies every save queued before
    /// it has also finished (Minor review fix).
    private func runSave() async {
        let previous = inFlightSaveTask
        let task = Task { [weak self] in
            await previous?.value
            guard let self else { return }
            await performSave()
        }
        inFlightSaveTask = task
        await task.value
    }

    /// Single choke point for writing the score to disk and refreshing the `ScoreItem` row. A no-op when there is
    /// nothing to save (`isDirty == false`) or once a revert has started (`isReverting`) — so a stray flush after a
    /// prior successful save, or one that lands mid-revert, costs nothing.
    private func performSave() async {
        guard let score, isDirty, !isReverting else { return }
        let destination = Self.saveDestination(for: scoreItem, scoresDirectory: scoresDirectory)
        // BEFORE the write, and only here: this is the last moment the file still holds the bytes the score was
        // imported with. Editing metadata does not touch the file, so nothing earlier can have moved them. A capture
        // that fails returns the item unchanged rather than throwing, so a full disk costs the original, not the edit.
        let itemToSave = await (try? originalStore.captureOriginalIfNeeded(for: scoreItem)) ?? scoreItem
        // `captureOriginalIfNeeded` is the method's one real suspension point (Infrastructure runs it detached), so
        // a `revertToOriginal()` that started while this call was suspended there is invisible to the guard above.
        // Re-check here, before the write that would race the store's own file swap: if a revert won that race, we
        // must not now overwrite the original it just restored (Critical 2 review fix).
        guard !isReverting else { return }
        do {
            try await gateway.saveScore(score, fileURL: destination.url, format: destination.format)
            let facts = try EditorFileFacts.hashAndSize(of: destination.url)
            let newItem = ScoreItem(
                id: itemToSave.id,
                title: itemToSave.title,
                subtitle: itemToSave.subtitle,
                composer: itemToSave.composer,
                arranger: itemToSave.arranger,
                lyricist: itemToSave.lyricist,
                copyright: itemToSave.copyright,
                instrumentationSummary: itemToSave.instrumentationSummary,
                localFileName: destination.isSiblingCopy
                    ? destination.url.lastPathComponent
                    : itemToSave.localFileName,
                contentHash: facts.contentHash,
                sizeBytes: facts.sizeBytes,
                lengthBeats: itemToSave.lengthBeats,
                defaultTempoBpm: itemToSave.defaultTempoBpm,
                primaryKey: itemToSave.primaryKey,
                addedAt: itemToSave.addedAt,
                lastOpenedAt: itemToSave.lastOpenedAt,
                tagIDs: itemToSave.tagIDs,
                isFavorite: itemToSave.isFavorite,
                deletedAt: itemToSave.deletedAt,
                museScoreMajorVersion: itemToSave.museScoreMajorVersion,
                sourcePDFFileName: itemToSave.sourcePDFFileName,
                sourcePDFContentHash: itemToSave.sourcePDFContentHash,
                pdfDerivedContentHash: itemToSave.pdfDerivedContentHash,
                pdfConversionFailed: itemToSave.pdfConversionFailed,
                originalFileName: itemToSave.originalFileName,
                originalContentHash: itemToSave.originalContentHash,
                originalProvenance: itemToSave.originalProvenance,
            )
            try await repository.saveScoreItem(newItem)
            scoreItem = newItem
            // Remember that it was THIS session that first put a sidecar there — `discardSessionEdits()` has to take
            // it back out again, or a score whose only edits were just thrown away would go on offering to revert to
            // an original it is already identical to.
            if !hasCapturedOriginal, newItem.canRevertToOriginal {
                capturedOriginalThisSession = true
            }
            hasCapturedOriginal = newItem.canRevertToOriginal
            if destination.isSiblingCopy {
                didSaveAsSiblingMSCZ = true
            }
            isDirty = false
        } catch {
            // Keep isDirty true so the next debounce tick or flush retries the write.
        }
    }

    /// Save format + URL policy: `.mscx`/`.mscz` sources save in place; every other source (MusicXML/MXL/MIDI) saves
    /// as a sibling `.mscz` next to it, since only the MuseScore encoder can represent note-edit round-trips. Pure —
    /// no file I/O.
    static func saveDestination(
        for item: ScoreItem,
        scoresDirectory: URL,
    ) -> (url: URL, format: ScoreFormat, isSiblingCopy: Bool) {
        if let format = ScoreFormat.detect(filename: item.localFileName), format == .mscx || format == .mscz {
            return (scoresDirectory.appending(path: item.localFileName), format, false)
        }
        let stem = URL(fileURLWithPath: item.localFileName).deletingPathExtension().lastPathComponent
        let siblingURL = scoresDirectory.appending(path: "\(stem).mscz")
        return (siblingURL, .mscz, true)
    }
}

// MARK: - External row refresh (Critical 1 review fix)

extension EditorViewModel {
    /// Stable identity of the row this session's saves and captures act on — safe to read from outside the module
    /// without exposing the whole (frequently stale, `@ObservationIgnored`) row itself.
    public var scoreItemID: ScoreItemID {
        scoreItem.id
    }

    /// Re-seeds the row this session's next capture/save will act on with whatever the caller's own
    /// `ScoreLibraryRepository` cache currently holds for this id. Call before `beginSession`.
    ///
    /// Needed because `scoreItem` is seeded once at `init` and this view model is reused for every edit session a
    /// Reader screen opens — nothing else here ever touches it between sessions. A revert performed through the
    /// score-info sheet shares the store but writes through the Reader's or the Library's OWN copy of the row,
    /// never this one, so without a refresh this instance keeps believing an original is captured under a sidecar
    /// name the store has already deleted. `OriginalCapture.plan` decides purely from that stale belief, so the
    /// next edit's autosave would write straight over the just-restored file with no backup, and the row would
    /// keep naming a sidecar that no longer exists. The same staleness also clobbers a plain title edit made from
    /// the sheet, which is why this refreshes the whole row rather than only the original-tracking fields.
    ///
    /// Ignores an item for a different id — that is a caller bug, not a different score's row to adopt.
    public func refreshRow(_ item: ScoreItem) {
        guard item.id == scoreItem.id else { return }
        scoreItem = item
        hasCapturedOriginal = item.canRevertToOriginal
    }
}
