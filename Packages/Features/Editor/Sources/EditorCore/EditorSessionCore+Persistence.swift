import Domain
import Foundation
import SheetMusicCore

extension EditorSessionCore {
    /// Writes the score to disk and refreshes the library row. A no-op when there is nothing to save
    /// (`isDirty == false`), so a stray flush after a prior successful save costs nothing.
    ///
    /// The debounce is the host's — a timer belongs where the run loop is. This is the choke point that timer fires
    /// into, and the one `endSession` is flushed through.
    ///
    /// `isolation:` makes this run wherever its caller runs rather than hopping to the generic executor. That is what
    /// lets a non-`Sendable` core be driven from the main actor on iOS and from a JNI thread on Android without
    /// either one sending it across a boundary.
    public func performSave(isolation: isolated (any Actor)? = #isolation) async {
        guard let score, isDirty, !isReverting else { return }
        let destination = Self.saveDestination(for: scoreItem, scoresDirectory: scoresDirectory)
        // BEFORE the write, and only here: this is the last moment the file still holds the bytes the score was
        // imported with. Editing metadata does not touch the file, so nothing earlier can have moved them. A capture
        // that fails returns the item unchanged rather than throwing, so a full disk costs the original, not the edit.
        let itemToSave = await (try? originals?.captureOriginalIfNeeded(for: scoreItem)) ?? scoreItem
        // `captureOriginalIfNeeded` is this method's one real suspension point (Infrastructure runs it detached), so
        // a revert that started while this call was suspended there is invisible to the guard above. Re-check here,
        // before the write that would race the store's own file swap: if the revert won that race, we must not now
        // overwrite the original it just restored.
        guard !isReverting else { return }
        do {
            try await writer.write(score, to: destination.url, format: destination.format)
            let facts = try fileFacts.hashAndSize(of: destination.url)
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
            try await writer.refreshRow(newItem)
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
            markSaved()
        } catch {
            // Keep isDirty true so the next debounce tick or flush retries the write.
        }
    }

    /// Re-seeds the row this session's next capture/save acts on with whatever the caller's own repository cache
    /// currently holds for this id. Call before `beginSession`.
    ///
    /// Needed because `scoreItem` is seeded once at `init` and a host reuses one session object across every edit
    /// session a screen opens. A revert performed through the score-info sheet shares the store but writes through
    /// that screen's OWN copy of the row, never this one, so without a refresh this instance keeps believing an
    /// original is captured under a sidecar name the store has already deleted — and the next edit's autosave would
    /// write straight over the just-restored file with no backup. The same staleness clobbers a plain title edit
    /// made from the sheet, which is why this refreshes the whole row rather than only the original-tracking fields.
    ///
    /// Ignores an item for a different id — that is a caller bug, not a different score's row to adopt.
    public func refreshRow(_ item: ScoreItem) {
        guard item.id == scoreItem.id else { return }
        scoreItem = item
        hasCapturedOriginal = item.canRevertToOriginal
    }

    /// Save format + URL policy: `.mscx`/`.mscz` sources save in place; every other source (MusicXML/MXL/MIDI) saves
    /// as a sibling `.mscz` next to it, since only the MuseScore encoder can represent note-edit round-trips. Pure —
    /// no file I/O.
    public static func saveDestination(
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
