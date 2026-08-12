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
            markSaved()
        } catch {
            // Keep isDirty true so the next debounce tick or flush retries the write.
        }
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
