import Domain
import EditorCore
import Foundation
import SheetMusicCore
import WireletProvided

/// What only Kotlin can do for this session.
///
/// `EditorFileFacts` on iOS is CryptoKit, which does not exist on Android, so the digest comes back over the wire
/// exactly as `LibraryAndroidStore` already sources it for import. **The hex format is load-bearing**: it has to
/// match what the importer wrote, or every save makes the library think it is looking at a new file.
@WireletProvided
public protocol EditorHostFiles {
    func sha256Hex(path: String) -> String
    func fileSize(path: String) -> Int64
}

/// Routes `FileFactsProviding` through the Kotlin seam.
///
/// `@unchecked Sendable` for the same reason `WireletBackedBlobStore` is: the wrapped `@WireletProvided` proxy is a
/// thin JNI forwarder that is not intrinsically `Sendable`, and the only holder is one `EditorSessionCore` driven
/// from one JNI call at a time.
struct HostFileFacts: FileFactsProviding, @unchecked Sendable {
    let files: EditorHostFiles

    func hashAndSize(of url: URL) throws -> (contentHash: String, sizeBytes: Int64) {
        (files.sha256Hex(path: url.path), files.fileSize(path: url.path))
    }
}

/// The writer seam, unimplemented in SP3 by design.
///
/// SP5 owns persistence: the MSCZ encode plus the POSIX write, and the Room row refresh behind a second
/// `@WireletProvided` method. Until then nothing calls it — the bridge never schedules a save and never flushes one.
///
/// **Android's `refreshRow` will be a partial update, and that is decided here rather than in SP5.** It writes
/// exactly the three columns a save derives — `localFileName`, `contentHash`, `sizeBytes` — keyed on the row's id,
/// which is what `ScoreFileWriting`'s own doc comment asks for ("so the list shows the new size and digest"). That
/// decision is what makes the stub row below permanently harmless, and it is the reason no `ScoreItem` wire
/// projection has to exist: a 20-field hand-maintained duplicate of a Domain type is exactly the drift §5.4 is
/// about. iOS keeps its whole-row repository write; the seam is per-platform by construction.
///
/// `preconditionFailure` rather than a thrown error, on purpose. `performSave` catches everything and keeps
/// `isDirty` true, so a thrown "unimplemented" is indistinguishable from a retriable save failure — it would just
/// mark the session permanently dirty and say nothing. A call here is a plan violation, not a runtime condition, and
/// a dev-time crash that names the plan beats a flag nobody reads. (`SheetMusicError.invalidEdit` in particular
/// would be the least honest spelling available: it is the one error this feature deliberately swallows as benign.)
struct UnimplementedScoreWriter: ScoreFileWriting, @unchecked Sendable {
    // Can't mark these `@available(*, unavailable)` — Swift rejects an unavailable protocol witness outright — so
    // `unavailable_function` is disabled per-method instead of satisfied; the doc comment above is the record of
    // why they trap on purpose. `async` is required by the `ScoreFileWriting` conformance even though this body
    // never awaits, so `async_without_await` is disabled alongside it (mirrors `NoopScoreServices.swift`).
    // swiftlint:disable:next unavailable_function async_without_await
    func write(_: Score, to _: URL, format _: ScoreFormat) async throws {
        preconditionFailure("persistence is SP5's; nothing may reach ScoreFileWriting before it lands")
    }

    // swiftlint:disable:next unavailable_function async_without_await
    func refreshRow(_: ScoreItem) async throws {
        preconditionFailure("persistence is SP5's; nothing may reach ScoreFileWriting before it lands")
    }
}
