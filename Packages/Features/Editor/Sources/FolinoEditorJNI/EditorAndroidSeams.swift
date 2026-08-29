import Domain
import EditorCore
import Foundation
import SheetMusicCore
import SheetMusicMSCX // MSCXEncoder / MSCZWriter — the save encodes in THIS image (spec §3)
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

    /// Puts the two columns a save derives back on the library row: the file the score now lives in, and its digest.
    ///
    /// A partial update, never a whole-row write — see `AndroidScoreWriter` below, and `EditorBridge`'s
    /// `stubRowPendingSave`, for the safety the two halves make together.
    func refreshRow(id: String, localFileName: String, contentHash: String)
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

/// Android's `ScoreFileWriting`: the MSCX/MSCZ encode plus the write, and the library row refresh behind the Kotlin
/// seam.
///
/// The encode happens **in this image**, because that is where the `Score` is (spec §3 — a `Score` cannot cross
/// between the process's two `SheetMusicCore` copies, only bytes can). The encoders and their defaults are the same
/// ones iOS reaches through `LiveScoreFileGateway.saveScore`: no options, `score.mscx` as the archive's main file, so
/// a file written on Android is the same file iOS would have written from the same score.
///
/// **`refreshRow` is a partial update of the two columns Android stores.** It writes `local_file_name` and
/// `content_hash` keyed on the row's id, which is what `ScoreFileWriting`'s own doc comment asks for ("so the list
/// shows the new size and digest"). `sizeBytes` is deliberately not among them: `score_records` has no such column
/// and nothing on Android reads a size, and adding one for a value nobody reads would cost a real migration on a
/// shipped schema.
///
/// That narrowness is what makes `EditorBridge.stubRowPendingSave` harmless: the stub row has only `id` and
/// `localFileName` real, and `EditorSessionCore.performSave` rebuilds the row from EVERY field of it before calling
/// here — so a whole-row Android writer would push those placeholders over the user's real title, tags and dates.
/// The two halves are one safety; do not change either without the other. It is also the reason no `ScoreItem` wire
/// projection has to exist: a 20-field hand-maintained duplicate of a Domain type is exactly the drift §5.4 is
/// about. iOS keeps its whole-row repository write; the seam is per-platform by construction.
///
/// `@unchecked Sendable` for the reason `HostFileFacts` is: the wrapped `@WireletProvided` proxy is a thin JNI
/// forwarder that is not intrinsically `Sendable`, and the only holder is one `EditorSessionCore` driven from one
/// JNI call at a time.
struct AndroidScoreWriter: ScoreFileWriting, @unchecked Sendable {
    let files: EditorHostFiles

    // `async` by conformance only; the body never suspends — hence the `async_without_await` waiver, which has to
    // sit against the declaration, so this note is a plain comment rather than a doc comment. The encode and the
    // write run on whichever thread the JNI op arrived on; `EditorBridge.flushSave` is where that thread is chosen
    // and why.
    // swiftlint:disable:next async_without_await
    func write(_ score: Score, to url: URL, format: ScoreFormat) async throws {
        switch format {
        case .mscx:
            try MSCXEncoder.encode(score, to: url)
        case .mscz:
            try MSCZWriter.write(score: score, to: url)
        case .musicXML, .mxl, .midi, .pdf:
            // Unreachable by construction: `EditorSessionCore.saveDestination` answers only `.mscx` or `.mscz`, and
            // every other source saves as a sibling `.mscz`. Thrown rather than trapped because `performSave`
            // catches it into "stay dirty and retry", which is the right answer for a case that cannot happen — and
            // because a `preconditionFailure` inside a JNI image aborts the whole process. Not
            // `SheetMusicError.invalidEdit`, which is the one error this feature deliberately swallows as benign.
            throw SheetMusicError.unsupportedFeature(
                name: "encode to .\(format.canonicalExtension)",
                location: "AndroidScoreWriter",
            )
        }
    }

    // swiftlint:disable:next async_without_await
    func refreshRow(_ item: ScoreItem) async throws {
        files.refreshRow(
            id: item.id.rawValue.uuidString,
            localFileName: item.localFileName,
            contentHash: item.contentHash,
        )
    }
}
