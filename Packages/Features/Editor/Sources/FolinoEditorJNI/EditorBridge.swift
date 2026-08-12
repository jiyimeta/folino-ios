import Domain
import EditorCore
import Foundation
import Observation
import SheetMusicCore
import SheetMusicEditWire
import SheetMusicMSCX
import WireletObservable

/// Android's face of one editing session: the authoritative `EditorSessionCore`, plus the projection Compose reads
/// and the intent frames Kotlin relays to the mirror.
///
/// The Apple counterpart is `EditorViewModel`, and the two are deliberately the same shape — call an op, then
/// re-read everything the core owns in one `sync()`. What differs is only what "publish" means: `@Observable`
/// properties there, `@WireletObservable` StateFlows here, plus the one thing iOS has no need of — the relay queue.
///
/// **This class holds no concurrency.** No `Task`, no `MainActor`. An Android JNI process pumps no main runloop, so
/// a `Task { @MainActor in … }` here would be created and never run (the bug `AnnotationSaveBridge.open` records).
/// Every op is synchronous, and the two things that are not — auditioning and autosave — stay requests the host
/// drains, exactly as `EditorSessionCore` leaves them.
@WireletObservable
@Observable
public final class EditorBridge {
    @ObservationIgnored private var core: EditorSessionCore?
    @ObservationIgnored private let files: EditorHostFiles
    /// Frames produced by the last op, waiting for `takeRelayFrames()`. Held here rather than drained straight into
    /// a return value because `sync()` runs after every op, including the ones that return nothing.
    @ObservationIgnored private var relayFrames: [EditBytesWire] = []

    // internal(set), not private(set): swift-wirelet's ObservableSchemaParser treats every stored `var` as mutable
    // (it ignores per-accessor access) and emits a same-module `_set` bridge, so `private(set)` fails the arm64
    // FolinoEditorJNI build the same way it did for `AnnotationSaveBridge.loadedDrawings`.
    //
    // The explicit `: Bool` is also load-bearing on its own: jextract's `missingTypeAnnotation` diagnostic fires
    // without it (see `ReaderPreferencesBridge.state`'s identical note), and SwiftFormat would otherwise strip it
    // as redundant (SwiftLint's `redundant_type_annotation` does not flag this one).
    // swiftformat:disable redundantType
    public internal(set) var isSessionActive: Bool = false
    // swiftformat:enable redundantType

    public init(files: EditorHostFiles) {
        self.files = files
    }

    // MARK: - Gates

    /// This image's build identity, for the §8.1 skew gate. The caller compares it with ssm's
    /// `nativeEngineVersionStamp()` and refuses to open a session on a mismatch: two different builds of
    /// `SheetMusicCore` cannot be trusted to plan an intent the same way, and every guarantee in this design rests
    /// on their doing so.
    @WireletExpose
    public func engineVersionStamp() -> Int64 {
        SheetMusicEngine.versionStamp
    }

    /// The authoritative score's digest, for the §8.3 divergence check. `0` outside a session — the caller treats
    /// that as a mismatch, which is correct: there is nothing to agree with.
    @WireletExpose
    public func scoreFingerprint() -> Int64 {
        core?.score?.stableFingerprint ?? 0
    }

    // MARK: - Lifecycle

    /// Opens a session over the score at `scorePath`, parsed in THIS image.
    ///
    /// Parsed rather than received: spec §3 — the two `SheetMusicCore` copies in the process cannot pass a `Score`
    /// between them. The invariant that makes the relay sound is that both sides start from the same score, and they
    /// do because both parse the same file with the same parser (§4).
    ///
    /// Returns `false` when the file cannot be read or parsed; the caller must not proceed to
    /// `nativeBeginEditSession` in that case — begin/end are paired across both sides, and a mirror opened against
    /// an authoritative session that never opened would answer `false` to the first relayed undo while the
    /// authoritative score had already moved (SP0's finding).
    @WireletExpose
    public func beginSession(scorePath: String, scoresDirectory: String, scoreId: String) -> Bool {
        guard let score = Self.parseScore(atPath: scorePath) else { return false }
        let localFileName = URL(fileURLWithPath: scorePath).lastPathComponent
        let item = Self.stubRowPendingSave(id: scoreId, localFileName: localFileName)
        let core = EditorSessionCore(
            scoreItem: item,
            scoresDirectory: URL(fileURLWithPath: scoresDirectory),
            fileFacts: HostFileFacts(files: files),
            writer: UnimplementedScoreWriter(),
            recordsRelayIntents: true,
        )
        core.beginSession(score: score)
        self.core = core
        relayFrames = []
        sync()
        return true
    }

    /// Drops the session. The host flushes any pending save first — SP5's job; there is nothing to flush yet.
    @WireletExpose
    public func endSession() {
        core?.endSession()
        core = nil
        relayFrames = []
        sync()
    }

    /// The authoritative score as `.mscz` bytes, for the §8.3 resync: the caller loads them into a fresh ssm handle
    /// and swaps. This is the recovery path the spec's rejected "re-encode and reload per edit" alternative is
    /// exactly right for — as a rare full resync rather than as the per-keystroke mechanism.
    ///
    /// `.v4` rather than deriving from the score's original source: `MSCXEncoderOptions`'s own default is `.v4`,
    /// Library's export path only ever picks `.v3` on an explicit user "save as MuseScore 3" choice, and a resync
    /// has no such choice to consult. `MSCZWriter` has a `Data`-returning overload for exactly this shape (no
    /// temp-file round trip needed — see `MSCZWriter.swift`'s `write(score:options:mainFileName:) throws -> Data`).
    @WireletExpose
    public func encodeScore() -> EditBytesWire {
        guard let score = core?.score,
              let data = try? MSCZWriter.write(score: score, options: MSCXEncoderOptions(targetVersion: .v4))
        else {
            return EditBytesWire(bytes: Data())
        }
        return EditBytesWire(bytes: data)
    }

    // MARK: - The mirror

    /// Re-reads everything the core owns and queues whatever it applied. The Android counterpart of
    /// `EditorViewModel.syncFromCore()`; Task 3 fills in the rest of the projection.
    func sync() {
        isSessionActive = core?.isSessionActive ?? false
        guard let core else { return }
        relayFrames.append(contentsOf: core.takeRelayIntents().map {
            EditBytesWire(bytes: EditIntentCodec.encode($0))
        })
    }

    /// Parses the score this session will edit. `MSCZReader.parse(contentsOf:)` — not a second format-dispatch
    /// ladder — the same call `LibraryAndroidStore` runs every pickable MuseScore file through
    /// (`LibraryAndroidStore.swift:309`, `:521`, `:1068`); Android only ever opens an edit session over a
    /// `.mscx`/`.mscz` source (`EditorSessionCore.saveDestination`'s save-in-place branch), so there is no other
    /// format to dispatch on here.
    private static func parseScore(atPath path: String) -> Score? {
        try? MSCZReader.parse(contentsOf: URL(fileURLWithPath: path))
    }

    /// A deliberately partial library row, named so nobody mistakes it for a real one.
    ///
    /// Only two fields are real: the id, which keys the Room row, and the file name, which is what decides
    /// `.mscx`/`.mscz`-in-place versus a sibling `.mscz`. Every other field is a neutral placeholder.
    ///
    /// **That is safe only because Android's `refreshRow` is a partial update of the three save-derived columns**
    /// — see `UnimplementedScoreWriter`, which is where that decision is written down. Note that
    /// `EditorSessionCore.performSave` rebuilds the row from EVERY field of this value before calling
    /// `refreshRow`, so a whole-row Android writer would push these placeholders over the user's real title, tags
    /// and dates. The two halves are one safety; do not implement either without the other.
    private static func stubRowPendingSave(id: String, localFileName: String) -> ScoreItem {
        ScoreItem(
            id: Domain.ScoreItemID(rawValue: UUID(uuidString: id) ?? UUID()),
            title: "",
            composer: nil,
            instrumentationSummary: nil,
            localFileName: localFileName,
            contentHash: "",
            sizeBytes: 0,
            lengthBeats: 0,
            defaultTempoBpm: 120,
            primaryKey: nil,
            addedAt: Date(),
            lastOpenedAt: nil,
            tagIDs: [],
            isFavorite: false,
        )
    }
}
