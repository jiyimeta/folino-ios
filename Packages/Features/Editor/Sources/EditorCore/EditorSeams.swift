import Domain
import Foundation
import SheetMusicCore

// The three things the editing session needs from its platform. Each is here rather than in `Domain` because each is
// a seam this feature owns: the core states WHEN a note should sound, WHAT a saved file's identity is, and WHERE a
// score is written — and the platform performs it.
//
// They are also the whole reason `EditorCore` can be cross-compiled. Every one of them stands in front of something
// Apple-only that would otherwise be linked into a target the Android bridge has to build.

/// Sounding one note as a preview, for the pitch keys and the drag (spec §5.6).
///
/// One method, not `PlaybackController`, which is thirty: audio-session lifetime, cursor streams, per-staff mixing.
/// The spec (§6.1) suggested Android implement `PlaybackController` since it is already a Domain protocol, but
/// implementing thirty methods to sound one note is not what that was reaching for — and the part the spec cared
/// about, that the DECISION to audition stays in the core, is unaffected. On Android this is a handful of lines over
/// the synth path the Reader already drives.
public protocol NoteAuditioning: Sendable {
    func playPreview(noteID: NoteID, in score: Score, duration: TimeInterval) async
}

/// A saved file's identity: the digest the library keys a score by, plus its size.
///
/// The iOS side is `CryptoKit`, which does not exist on Android; there the digest comes from Kotlin, exactly as
/// `LibraryAndroidStore` already supplies it for import. **The hex-digest format is load-bearing on both sides** — it
/// has to match what the importer wrote, or every save makes the library think it is looking at a new file.
public protocol FileFactsProviding: Sendable {
    func hashAndSize(of url: URL) throws -> (contentHash: String, sizeBytes: Int64)
}

/// Performing the save the core has decided on.
///
/// The policy — which URL, which format, whether this source has to be written as a sibling `.mscz` — is
/// `saveDestination`'s and stays in the core. What crosses the seam is only the doing: write these bytes, then
/// refresh the library row so the list shows the new size and digest. On Android both halves land on Room and
/// `filesDir` rather than on a gateway and a repository.
///
/// `Sendable` like the other two, and iOS satisfies it by isolating its adapter to the main actor rather than by
/// making its parts sendable: `ScoreLibraryRepository` is an `Observable` class the library list observes, so it
/// belongs to the main actor and a global-actor-isolated adapter is `Sendable` for exactly that reason. The protocol
/// stays un-isolated so Android can write through Room from whatever thread the JNI call arrived on.
public protocol ScoreFileWriting: Sendable {
    func write(_ score: Score, to url: URL, format: ScoreFormat) async throws
    func refreshRow(_ item: ScoreItem) async throws
}
