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
            await self?.performSave()
        }
    }

    /// Cancel the debounce and write now. Safe when nothing is pending. Called by endSession and (Task 15) on
    /// scene-background.
    public func flushPendingSave() async {
        autosaveTask?.cancel()
        autosaveTask = nil
        await performSave()
    }

    /// Single choke point for writing the score to disk and refreshing the `ScoreItem` row. A no-op when there is
    /// nothing to save (`isDirty == false`) so a stray flush after a prior successful save costs nothing.
    private func performSave() async {
        guard let score, isDirty else { return }
        let destination = Self.saveDestination(for: scoreItem, scoresDirectory: scoresDirectory)
        do {
            try await writer.write(score, to: destination.url, format: destination.format)
            let facts = try fileFacts.hashAndSize(of: destination.url)
            let newItem = ScoreItem(
                id: scoreItem.id,
                title: scoreItem.title,
                subtitle: scoreItem.subtitle,
                composer: scoreItem.composer,
                arranger: scoreItem.arranger,
                lyricist: scoreItem.lyricist,
                copyright: scoreItem.copyright,
                instrumentationSummary: scoreItem.instrumentationSummary,
                localFileName: destination.isSiblingCopy ? destination.url.lastPathComponent : scoreItem.localFileName,
                contentHash: facts.contentHash,
                sizeBytes: facts.sizeBytes,
                lengthBeats: scoreItem.lengthBeats,
                defaultTempoBpm: scoreItem.defaultTempoBpm,
                primaryKey: scoreItem.primaryKey,
                addedAt: scoreItem.addedAt,
                lastOpenedAt: scoreItem.lastOpenedAt,
                tagIDs: scoreItem.tagIDs,
                isFavorite: scoreItem.isFavorite,
                deletedAt: scoreItem.deletedAt,
                museScoreMajorVersion: scoreItem.museScoreMajorVersion,
            )
            try await writer.refreshRow(newItem)
            scoreItem = newItem
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
