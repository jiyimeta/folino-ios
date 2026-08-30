import Dispatch // DispatchSemaphore — `flushSave` joins an async save across the synchronous JNI boundary
import Domain
import EditorCore
import Foundation
import Observation
import SheetMusicCore
import SheetMusicEditWire
import SheetMusicLoader // ScoreLoader.loadScore(contentsOf:) — the one format-dispatch
import SheetMusicMSCX
import WireletObservable

// swiftlint:disable file_length
// The op vocabulary and the projection both have to live in this one class body, in this one file: swift-wirelet's
// `ObservableSchemaParser` (the Kotlin/JNI codegen behind `@WireletObservable`) reads `@WireletExpose` methods and
// stored properties only from the literal `class` declaration's own member list, and Swift has no partial classes
// — an `extension EditorBridge` in a second file is invisible to it, so every op declared there would silently
// vanish from `EditorBridgeViewModel.kt` and its native JNI bridges. `swift-sheet-music`'s `LayoutBridge.swift`
// carries the identical disable for the identical reason (a jextract-facing bridge type that cannot be split).

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

    // MARK: - The projection Compose reads
    //
    // Counters first, for the same reason `EditorViewModel` keeps them: `revision` bumps on apply/undo/redo and is
    // what a relayout keys off; `appliedIntentCount` bumps ONLY on a genuine apply; `selectionRevision` bumps on
    // every placement, changed or not, so a repeat placement is not silently swallowed.
    public internal(set) var revision: Int32 = 0
    public internal(set) var appliedIntentCount: Int32 = 0
    public internal(set) var selectionRevision: Int32 = 0

    // The explicit `: Bool` on every property below is load-bearing, not decorative: jextract's `missingTypeAnnotation`
    // diagnostic silently drops a `Bool` property from the generated Kotlin bindings without it (see
    // `isSessionActive`'s identical note above), and SwiftFormat would otherwise strip it as redundant.
    // swiftformat:disable redundantType
    public internal(set) var canUndo: Bool = false
    public internal(set) var canRedo: Bool = false

    public internal(set) var hasEditTarget: Bool = false
    public internal(set) var isNoteSelected: Bool = false
    public internal(set) var hasSelectionCallout: Bool = false
    public internal(set) var canWriteRest: Bool = false
    public internal(set) var canTie: Bool = false
    public internal(set) var isSelectionTied: Bool = false
    public internal(set) var canAppendTiedNote: Bool = false
    public internal(set) var isCaretInTuplet: Bool = false
    // swiftformat:enable redundantType

    /// The armed length as `NoteDurationWire`'s discriminator (1 = whole … 9 = 256th, 10 = measure, 11 = fraction),
    /// or 0 for "nothing armed". Deliberately ssm's numbering rather than a second one of our own: the same integer
    /// already crosses this process inside every relayed intent, and two spellings of one enum is exactly the drift
    /// spec §5.4 exists to prevent.
    public internal(set) var armedDurationKind: Int32 = 0
    public internal(set) var armedDots: Int32 = 0
    // swiftformat:disable redundantType
    public internal(set) var isAddToChordArmed: Bool = false
    // swiftformat:enable redundantType
    public internal(set) var armedTuplet: Int32 = 3

    // swiftformat:disable redundantType
    /// Whether this session has moved the score away from where it opened — what the discard control is gated on.
    public internal(set) var sessionHasEdits: Bool = false

    /// Whether the row records an original to go back to. Always `false` on Android today: the core is built with
    /// no originals store, because there is none — see `revertToOriginal()` below.
    public internal(set) var canRevertToOriginal: Bool = false

    /// Whether a save has written this score's edits to a NEW file — a sibling `.mscz` next to a MusicXML / MXL /
    /// MIDI source, which is the only format that can carry a note edit. Latched by `EditorSessionCore`, so it stays
    /// true for the rest of the session and the host can show its notice once.
    public internal(set) var didSaveAsSiblingMSCZ: Bool = false
    // swiftformat:enable redundantType

    /// `EditorSessionEndMode` as a discriminator: 0 = commitUnchanged, 1 = revert, 2 = commitEdited. An integer
    /// rather than a second spelling of the enum, for the reason `armedDurationKind` is one.
    public internal(set) var sessionEndModeKind: Int32 = 0

    /// The SELECTED element's own length, in the same numbering — what the callout shows. Distinct from the armed
    /// length, which describes the next note rather than this one.
    public internal(set) var calloutDurationKind: Int32 = 0
    public internal(set) var calloutDots: Int32 = 0

    /// Mirrored both ways: Kotlin sets it from the voice selector, the core reads it when planning input.
    public internal(set) var activeVoice: Int32 = 0

    /// The selected item and the caret, as the same `ScoreItemID` bytes ssm speaks.
    ///
    /// Bytes rather than fields because of what the host does with them: `nativeEditingCaretFrame(handle, itemBytes)`
    /// wants exactly this encoding back, and re-projecting the ID into integers here would mean Kotlin re-encoding
    /// it there — a second spelling of ssm's own schema, in Kotlin, which is what §5.4 rules out.
    public internal(set) var selectedItemFrame: EditBytesWire?
    public internal(set) var caretItemFrame: EditBytesWire?

    static func frame(for item: SheetMusicCore.ScoreItemID?) -> EditBytesWire? {
        item.map { EditBytesWire(bytes: ScoreItemIDCodec.encode($0)) }
    }

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

    // MARK: Synchronous reads of two projection counters
    //
    // `revision` and `appliedIntentCount` are also published as projection properties, and the relay needs both
    // *the instant an op returns* — it decides whether an undo actually moved the score, and therefore whether to
    // drive the mirror's stack, by comparing them across the call. The projection cannot answer that question:
    // `@WireletObservable`'s generated view model republishes every property with
    // `viewModelScope.launch(Dispatchers.Main) { … }`, and `Dispatchers.Main` is not the immediate dispatcher, so on
    // Android's main thread — the thread the relay runs on — the new value is not visible until after the relay's
    // whole op has returned. Reading the StateFlow there deterministically yields the PRE-op value, which read as
    // "the undo was refused" and silently skipped the mirror entirely.
    //
    // So the relay reads these two through their own synchronous ops instead, exactly the way `scoreFingerprint()`
    // already answers straight out of the core. The projection properties stay — Compose collects them — but they
    // are for display, not for control flow.
    //
    // The `Now` suffix is forced, for the reason `armDots` is: jextract derives a native accessor for each
    // projection property from its name, so an op literally named `revision` would be a duplicate JNI symbol rather
    // than a Swift overload.

    /// The core's `revision`, read synchronously. `0` outside a session, matching what `sync()` publishes.
    @WireletExpose
    public func revisionNow() -> Int32 {
        Int32(core?.revision ?? 0)
    }

    /// The core's `appliedIntentCount`, read synchronously. `0` outside a session, matching what `sync()` publishes.
    @WireletExpose
    public func appliedIntentCountNow() -> Int32 {
        Int32(core?.appliedIntentCount ?? 0)
    }

    /// The core's `hasEditTarget`, read synchronously — the SAME answer `hasEditTarget` publishes, reached by a
    /// channel that cannot drop it.
    ///
    /// The projection reaches Kotlin through `withObservationTracking`, whose `onChange` fires at **willSet — before
    /// the new value is stored**. The generated handler answers that by posting a re-read to the main thread, so a
    /// re-read that overtakes the still-in-flight store reads the OLD value and re-arms on it; the store then
    /// completes without firing the registration it already consumed. Any projected property can lose an update
    /// that way, and it stays lost until the next assignment to that property.
    ///
    /// For most of them the next op fixes it. Not this one: `hasEditTarget` is what makes the whole pad live
    /// (`EditingPad`'s `enabled`), so losing its false → true leaves a pad that cannot be pressed — and a pad that
    /// cannot be pressed produces no next op. The score still shows the selection tint and the callout, because
    /// their own properties happened to win the race, which is exactly how it reads to a user: "a note is selected
    /// but the keys are dead."
    ///
    /// So Android reads this one through the relay's funnel instead, the same way it already reads `revisionNow()`
    /// and `appliedIntentCountNow()` — the repo's standing answer to this channel being stale right after an op.
    /// **The root fix is swift-wirelet's**: the notification has to be delivered after the store, not before it.
    /// Until that lands, this is the one property whose staleness is not self-healing.
    @WireletExpose
    public func hasEditTargetNow() -> Bool {
        core?.hasEditTarget ?? false
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
    ///
    /// Ends any already-open session first, so a caller that begins twice without an intervening `endSession()`
    /// still gets "one session, or none" rather than a leaked one: without this, a parse failure on the second
    /// call would return `false` while the first session stayed open and `isSessionActive` stayed `true`, breaking
    /// the caller's "`false` means no session" inference.
    @WireletExpose
    public func beginSession(scorePath: String, scoresDirectory: String, scoreId: String) -> Bool {
        if core != nil {
            endSession()
        }
        guard let score = Self.parseScore(atPath: scorePath) else { return false }
        let localFileName = URL(fileURLWithPath: scorePath).lastPathComponent
        let item = Self.stubRowPendingSave(id: scoreId, localFileName: localFileName)
        let core = EditorSessionCore(
            scoreItem: item,
            scoresDirectory: URL(fileURLWithPath: scoresDirectory),
            fileFacts: HostFileFacts(files: files),
            writer: AndroidScoreWriter(files: files),
            recordsRelayIntents: true,
        )
        core.beginSession(score: score)
        self.core = core
        relayFrames = []
        sync()
        return true
    }

    /// Drops the session. The host flushes any pending save first — see `EditSessionRelay.close`, which calls
    /// `flushSave()` before this. Ending without that flush loses whatever the debounce had not yet written.
    @WireletExpose
    public func endSession() {
        core?.endSession()
        core = nil
        relayFrames = []
        sync()
    }

    /// Writes the session's pending edits, if any. A no-op when nothing changed since the last save.
    ///
    /// The debounce that decides WHEN this runs is Kotlin's, for the reason `EditorSessionCore.performSave`'s own doc
    /// gives — a timer belongs where the run loop is, and this image has none. `DebouncedAutosave` is the Android
    /// counterpart of iOS's `EditorViewModel.scheduleAutosave`.
    ///
    /// Synchronous, and blocking, on purpose. `performSave` is `async`; a `@WireletExpose` op cannot await, so the
    /// `Task` is joined with a `DispatchSemaphore` exactly as `AnnotationSaveBridge.open` does. The same argument for
    /// why that cannot deadlock holds here: the save's only nominal suspension point is
    /// `originals?.captureOriginalIfNeeded`, and Android builds the core with no originals store, so the awaited work
    /// is a straight-line encode and write with nothing to starve the cooperative pool on.
    ///
    /// It blocks the caller's thread for the length of an MSCZ encode, which on a Pixel 8a measured 160-230 ms even
    /// for a small score. That is affordable only because the caller is NOT the thread that draws: `EditorBridge` is
    /// single-threaded by construction, so rather than make it concurrent the host moves the one thread it runs on —
    /// see `ConfinedEditSessionOps`, which posts every op and every save to a dedicated executor. Blocking that
    /// thread is exactly right; blocking Compose's would not be.
    @WireletExpose
    public func flushSave() {
        guard let core else { return }
        let semaphore = DispatchSemaphore(value: 0)
        Task {
            await core.performSave()
            semaphore.signal()
        }
        semaphore.wait()
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
    ///
    /// Empty bytes mean failure — either there is no open session, or the encode itself threw — and the caller must
    /// treat both the same way: there is no score here to resync with.
    @WireletExpose
    public func encodeScore() -> EditBytesWire {
        guard let score = core?.score,
              let data = try? MSCZWriter.write(score: score, options: MSCXEncoderOptions(targetVersion: .v4))
        else {
            return EditBytesWire(bytes: Data())
        }
        return EditBytesWire(bytes: data)
    }

    // MARK: - The op vocabulary Compose calls
    //
    // One method per key, and every one of them is "ask the core, then re-read the core" — the decisions all live
    // in `EditorSessionCore`, shared with iOS.
    //
    // **Nothing here may branch on score content.** A conditional in this file is a rule that exists on Android and
    // not on iOS, which is precisely what the repo's parity rule forbids; if a key needs to decide something, the
    // decision belongs in `EditorCore` where both platforms get it.

    // MARK: Pad keys

    /// A letter key C…B. `letter` is a one-character string because the wire has no `Character`; a longer string
    /// takes its first character, and an empty one is inert.
    @WireletExpose
    public func inputPitch(letter: String) {
        guard let character = letter.first else { return }
        core?.inputPitch(letter: character)
        sync()
    }

    @WireletExpose
    public func deleteSelection() {
        core?.deleteSelection()
        sync()
    }

    @WireletExpose
    public func writeRest() {
        core?.writeRest()
        sync()
    }

    /// Arms a length by `NoteDurationWire`'s discriminator (see `durationKind`). Unknown values are ignored rather
    /// than defaulted — arming the wrong length silently is worse than not arming.
    @WireletExpose
    public func armDuration(kind: Int32) {
        guard let duration = Self.duration(fromKind: kind) else { return }
        core?.setDuration(duration)
        sync()
    }

    @WireletExpose
    public func toggleArmedDot() {
        core?.toggleArmedDot()
        sync()
    }

    /// Named `armDots` rather than iOS's `setArmedDots` (see `EditorViewModel+Ops.setArmedDots`): jextract derives a
    /// native setter for every `internal(set)` projection property from its name — `armedDots` already produces
    /// `Java_..._setArmedDots`, and an op of that exact name is a duplicate JNI symbol, not a Swift overload, so it
    /// fails the link. The two platforms stay the same shape; only this one symbol's spelling is forced apart.
    ///
    /// The constraint is jextract's *native symbol* table, one layer below Kotlin: wirelet's observable codegen
    /// names the property's Kotlin setter `updateArmedDots`, so `GeneratedEditBridging` sees no clash at all and
    /// says so in its own doc. Renaming this back to `setArmedDots` for parity therefore looks safe from the Kotlin
    /// side and breaks the arm64 link — a failure that appears only when cross-compiling. Do not.
    @WireletExpose
    public func armDots(_ dots: Int32) {
        core?.setArmedDots(Int(dots))
        sync()
    }

    // MARK: Callout keys (the selected element's own length)

    @WireletExpose
    public func setSelectionDuration(kind: Int32) {
        guard let duration = Self.duration(fromKind: kind) else { return }
        core?.setSelectionDuration(duration)
        sync()
    }

    @WireletExpose
    public func setSelectionDots(_ dots: Int32) {
        core?.setSelectionDots(Int(dots))
        sync()
    }

    @WireletExpose
    public func toggleSelectionDot() {
        core?.toggleSelectionDot()
        sync()
    }

    // MARK: Pitch

    @WireletExpose
    public func shiftPitch(bySemitones delta: Int32) {
        core?.shiftPitch(bySemitones: Int(delta))
        sync()
    }

    @WireletExpose
    public func shiftOctave(by octaves: Int32) {
        core?.shiftOctave(by: Int(octaves))
        sync()
    }

    /// `raw` is the accidental's raw value, or the empty string for "none" (natural is its own raw value, and is not
    /// the same thing as none — none removes the accidental, natural writes one).
    @WireletExpose
    public func setAccidental(raw: String) {
        core?.setAccidental(raw.isEmpty ? nil : Accidental(rawValue: raw))
        sync()
    }

    // MARK: Chord, tie, tuplet (second pass in the UI; the ops exist from the start)

    @WireletExpose
    public func toggleAddToChord() {
        core?.toggleAddToChord()
        sync()
    }

    @WireletExpose
    public func removeSelectedNoteFromChord() {
        core?.removeSelectedNoteFromChord()
        sync()
    }

    @WireletExpose
    public func toggleTie() {
        core?.toggleTie()
        sync()
    }

    @WireletExpose
    public func appendTiedNote() {
        core?.appendTiedNote()
        sync()
    }

    @WireletExpose
    public func createTuplet(actualNotes: Int32) {
        core?.createTuplet(actualNotes: Int(actualNotes))
        sync()
    }

    @WireletExpose
    public func removeTuplet() {
        core?.removeTuplet()
        sync()
    }

    // MARK: Selection

    /// A tap, already resolved to an item by `nativeEditingHitTest` — which is also where the hidden-staff
    /// re-addressing happens, so the ID arriving here is in the SCORE's addressing, not the rendered document's.
    ///
    /// Empty bytes mean the tap landed on paper. That deselects, deliberately: the same "a tap off any staff band
    /// clears the selection" policy iOS has had since the hit-test ladder moved into ssm, and the reason
    /// `editingHitTest` answers "nothing" rather than rescuing every near miss.
    ///
    /// `selectFromTap`, not `select`: a tap that lands on a note also previews it, and that rule is the core's so
    /// that both platforms get one answer to "which taps sound" — see `EditorSessionCore.selectFromTap`. The sound
    /// itself is the host's, taken from `takePendingAudition()` below.
    @WireletExpose
    public func selectItem(frame: EditBytesWire) {
        guard !frame.bytes.isEmpty else {
            core?.selectFromTap(nil)
            sync()
            return
        }
        guard let item = try? ScoreItemIDCodec.decode(frame.bytes) else { return }
        core?.selectFromTap(item)
        sync()
    }

    /// The selection the reader was already on, carried into the session that just opened — Android's half of what
    /// `EditableReaderScreen` does with `ReaderEditingHost.pendingSelection`. Empty bytes mean nothing was
    /// remembered, and the session opens blank with an inert pad, exactly as iOS does.
    ///
    /// `selectCarriedItem`, not `selectItem`: the rules that separate the two — drop an ID this score no longer
    /// contains, and sound nothing — are the core's, so both platforms get one answer. See
    /// `EditorSessionCore.selectCarriedItem`.
    @WireletExpose
    public func selectCarriedItem(frame: EditBytesWire) {
        guard !frame.bytes.isEmpty else {
            core?.selectCarriedItem(nil)
            sync()
            return
        }
        guard let item = try? ScoreItemIDCodec.decode(frame.bytes) else { return }
        core?.selectCarriedItem(item)
        sync()
    }

    // MARK: Navigation and voice

    @WireletExpose
    public func selectPreviousElement() {
        core?.selectPreviousElement()
        sync()
    }

    @WireletExpose
    public func selectNextElement() {
        core?.selectNextElement()
        sync()
    }

    /// Named `setVoice` rather than `setActiveVoice`: the `activeVoice` projection property already produces a
    /// jextract-generated native setter named `Java_..._setActiveVoice` (see `armDots`'s note above for why,
    /// including why the generated Kotlin gives no hint of the clash), which a same-named op would collide with at
    /// link time.
    @WireletExpose
    public func setVoice(_ voice: Int32) {
        core?.activeVoice = Int(voice)
        sync()
    }

    /// Mirrored in from the transport. The core drops the selection when playback starts — the playhead, not the
    /// selection, is where the music is from that moment.
    @WireletExpose
    public func setPlaybackActive(_ active: Bool) {
        core?.isPlaybackActive = active
        sync()
    }

    // MARK: Undo / redo
    //
    // These do NOT produce relay frames: the mirror keeps its own stacks, fed the same intents, so the host drives
    // them with `nativeEditUndo` / `nativeEditRedo`. Replaying an inverse as an intent would put the two stacks out
    // of step immediately.

    @WireletExpose
    public func undo() {
        core?.undo()
        sync()
    }

    @WireletExpose
    public func redo() {
        core?.redo()
        sync()
    }

    // MARK: Ending the session

    /// Throws this session's edits away: unwind the command stack back to where the session opened, then write that
    /// score back over whatever the autosave had already put on disk.
    ///
    /// The ordering is iOS's (`EditorViewModel.discardSessionEdits`), and each step is load-bearing:
    ///
    /// - Mark discarded even when there is nothing to unwind — leaving without edits must not deposit a stack the
    ///   user has just declined.
    /// - Only write if the unwind actually landed back where the session opened. It can fail to (an adopted
    ///   session's stack reaches back past this session's start), and half-unwound bytes are worse than the edits.
    /// - `markDirtyForDiscardFlush()` before the save, because the unwind itself does not dirty the session and
    ///   `performSave` no-ops on a clean one — without it the file would keep the edits that were just discarded.
    ///
    /// The host cancels its armed autosave before calling this (`EditSessionRelay.discardSessionEdits`): the pending
    /// write is for the score being thrown away, and it must not land after this one.
    ///
    /// What iOS does and this cannot: take back an original its first save captured. Android has no originals store
    /// — see `revertToOriginal()` below and its parity marker.
    ///
    /// Produces no relay frames: like undo, the unwind drives `ScoreEditSession` directly rather than through
    /// `apply`. The host must therefore reconcile the mirror by fingerprint afterwards rather than by replaying
    /// frames — see `EditSessionRelay.discardSessionEdits`.
    @WireletExpose
    public func discardSessionEdits() {
        guard let core else { return }
        core.markSessionDiscarded()
        guard core.sessionHasEdits else {
            sync()
            return
        }
        core.unwindSessionEdits()
        guard !core.sessionHasEdits else {
            sync()
            return
        }
        core.markDirtyForDiscardFlush()
        // Ends with its own `sync()`.
        flushSave()
    }

    // PARITY(android): revert to original — needs an Android `ScoreOriginalStore` (sidecar copy + restore), the
    //   `original*` Room columns and a migration, and `RevertPolicy`'s warnings bridged across. The writer it would
    //   restore through exists (`AndroidScoreWriter`); what is missing is the original to restore. Delete this
    //   marker when that lands.

    /// Restores the file from the copy taken when the score was imported. Answers `false` when it could not.
    ///
    /// **Always `false` today.** The core is constructed with no `ScoreOriginalStore` (its `originals` is nil), so
    /// it throws `EditorRevertUnavailable` — and there is nothing for a store to be built on yet either: Android has
    /// no sidecar copy and no `original*` columns in the Room row. (The writer is no longer the missing half; SP5
    /// landed it.) The op and its call site exist now so the placement is settled and whoever builds the store fills
    /// the body rather than re-deciding the UI.
    ///
    /// It answers rather than traps on purpose. A `preconditionFailure` here would abort the whole process from
    /// inside a JNI image — the least readable failure available — for a state that is not a plan violation but
    /// simply "not built yet". The forcing function is the parity marker below, which `Scripts/parity-report.py`
    /// turns into a ledger row that the `parity-ledger` pre-commit hook will not let rot.
    @WireletExpose
    public func revertToOriginal() -> Bool {
        false
    }

    // MARK: The relay queue

    /// Takes the intent frames produced since the last call, in order. The host relays each one to the mirror with
    /// `nativeApplyEditIntent`, in the same order, before anything reads the mirror's layout.
    @WireletExpose
    public func takeRelayFrames() -> [EditBytesWire] {
        defer { relayFrames.removeAll() }
        return relayFrames
    }

    // MARK: The pending audition

    /// Takes the note the last op decided to preview, as a `NoteID` wire — empty bytes when it decided nothing
    /// should sound. The Android counterpart of `EditorViewModel.performPendingAudition()`.
    ///
    /// The core decides WHICH note sounds and after which ops (`pendingAudition` — set after note input, a pitch or
    /// octave shift, an accidental and an add-to-chord, and after a tap that lands on a note; never after delete,
    /// duration, tie, tuplet, undo or redo, which produce no "resulting pitch" worth sounding). Making the sound is
    /// the host's job, because it needs an audio engine and something to schedule the note-off on, and this image
    /// has neither — the same split iOS has, with `EditSessionRelay` standing in for `EditorViewModel`.
    ///
    /// Synchronous, and deliberately NOT a projection property, for the reason `revisionNow()` spells out: the
    /// generated view model republishes projections through a posted `Dispatchers.Main` block, so a StateFlow read
    /// on the relay's own thread would answer with the value from before the op — here that means previewing the
    /// PREVIOUS note on every key, or nothing at all on the first.
    @WireletExpose
    public func takePendingAudition() -> EditBytesWire {
        guard let noteID = core?.takePendingAudition() else { return EditBytesWire(bytes: Data()) }
        return EditBytesWire(bytes: PathIDCodecs.encode(noteID))
    }

    /// `EditorSessionEndMode` → the discriminator `sessionEndModeKind` carries.
    static func endModeKind(_ mode: EditorSessionEndMode) -> Int32 {
        switch mode {
        case .commitUnchanged: 0
        case .revert: 1
        case .commitEdited: 2
        }
    }

    /// `NoteDuration` → `NoteDurationWire`'s discriminator. Kept here rather than reaching into ssm's wire struct so
    /// the projection has no dependency on a type whose Kotlin model is not generated for this module; the numbering
    /// is the contract, and the tests in `EditIntentCodecTests` are what pin it.
    static func durationKind(_ duration: NoteDuration?) -> Int32 {
        switch duration {
        case .none: 0
        case .whole: 1
        case .half: 2
        case .quarter: 3
        case .eighth: 4
        case .sixteenth: 5
        case .thirtySecond: 6
        case .sixtyFourth: 7
        case .oneTwentyEighth: 8
        case .twoFiftySixth: 9
        case .measure: 10
        case .fraction: 11
        }
    }

    static func duration(fromKind kind: Int32) -> NoteDuration? {
        switch kind {
        case 1: .whole
        case 2: .half
        case 3: .quarter
        case 4: .eighth
        case 5: .sixteenth
        case 6: .thirtySecond
        case 7: .sixtyFourth
        case 8: .oneTwentyEighth
        case 9: .twoFiftySixth
        case 10: .measure
        default: nil
        }
    }

    // MARK: - The mirror

    /// Re-reads everything the core owns and queues whatever it applied. The Android counterpart of
    /// `EditorViewModel.syncFromCore()` — call an op, then re-read everything in one place, so it is impossible for
    /// an op to mutate the score without also queueing its relay frames.
    func sync() {
        isSessionActive = core?.isSessionActive ?? false
        guard let core else {
            // Reset EVERYTHING the session owned. An asymmetric reset — clearing the booleans but leaving the armed
            // length and the counters behind — reads as a bug even where it is inert, and one of these is not inert:
            // Compose keeps collecting these StateFlows after a session ends, so a stale `armedDurationKind` lights
            // a pad key for a session that no longer exists. `armedTuplet` is the one exception and stays put: the
            // core deliberately survives `beginSession` with it, because it is a preference about how you are
            // writing rather than state about one score.
            revision = 0
            appliedIntentCount = 0
            selectionRevision = 0
            canUndo = false
            canRedo = false
            hasEditTarget = false
            isNoteSelected = false
            hasSelectionCallout = false
            canWriteRest = false
            canTie = false
            isSelectionTied = false
            canAppendTiedNote = false
            isCaretInTuplet = false
            armedDurationKind = 0
            armedDots = 0
            isAddToChordArmed = false
            calloutDurationKind = 0
            calloutDots = 0
            sessionHasEdits = false
            canRevertToOriginal = false
            didSaveAsSiblingMSCZ = false
            sessionEndModeKind = 0
            activeVoice = 0
            selectedItemFrame = nil
            caretItemFrame = nil
            return
        }
        revision = Int32(core.revision)
        appliedIntentCount = Int32(core.appliedIntentCount)
        selectionRevision = Int32(core.selectionRevision)
        canUndo = core.canUndo
        canRedo = core.canRedo
        hasEditTarget = core.hasEditTarget
        isNoteSelected = core.isNoteSelected
        hasSelectionCallout = core.hasSelectionCallout
        canWriteRest = core.canWriteRest
        canTie = core.canTie
        isSelectionTied = core.isSelectionTied
        canAppendTiedNote = core.canAppendTiedNote
        isCaretInTuplet = core.isCaretInTuplet
        armedDurationKind = Self.durationKind(core.armedDuration)
        armedDots = Int32(core.armedDots)
        isAddToChordArmed = core.isAddToChordArmed
        armedTuplet = Int32(core.armedTuplet)
        calloutDurationKind = Self.durationKind(core.selectedDuration?.base)
        calloutDots = Int32(core.selectedDuration?.dots ?? 0)
        sessionHasEdits = core.sessionHasEdits
        canRevertToOriginal = core.hasCapturedOriginal
        didSaveAsSiblingMSCZ = core.didSaveAsSiblingMSCZ
        sessionEndModeKind = Self.endModeKind(core.sessionEndMode)
        activeVoice = Int32(core.activeVoice)
        selectedItemFrame = Self.frame(for: core.selectedItem)
        caretItemFrame = Self.frame(for: core.caretItem)
        relayFrames.append(contentsOf: core.takeRelayIntents().map {
            EditBytesWire(bytes: EditIntentCodec.encode($0))
        })
    }

    /// Parses the score this session will edit, through ssm's one format-dispatch.
    ///
    /// This used to call `MSCZReader.parse(contentsOf:)` directly, on the reasoning that Android only ever opens a
    /// session over a `.mscx`/`.mscz` source. That reasoning was wrong twice over. `EditorSessionCore` handles every
    /// format — `saveDestination` saves MusicXML/MXL/MIDI sources as a sibling `.mscz` — and once Android's import
    /// accepted the same six formats iOS does, a `.musicxml` score reached here and `MSCZReader`, which opens a ZIP
    /// container, could not read it. `beginSession` then returned `false`, which the Reader maps to
    /// `UNAVAILABLE_NO_SCORE`, which by design shows no dialog: tapping "Edit notes" did nothing at all, with
    /// nothing anywhere to say why.
    ///
    /// Sniffing is also what makes `beginSession`'s own invariant true rather than coincidental. That doc says both
    /// sides "parse the same file with the same parser" — but the mirror reaches the score through
    /// `ScoreHandle.load`, which sniffs, while this side trusted a container format. For `.mscz` the two agreed by
    /// luck; now they agree by construction.
    private static func parseScore(atPath path: String) -> Score? {
        try? ScoreLoader.loadScore(contentsOf: URL(fileURLWithPath: path))
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
