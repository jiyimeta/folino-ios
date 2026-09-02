import Domain
import Foundation

/// Loads, seeds, and persists `ReaderPreferences` for a single `ScoreItem`. The store re-runs
/// `ReaderPreferences.init` after every mutation so the type's clamping rules always apply, and
/// it never reaches into the view model's sub-models — distribution of loaded preferences is the
/// caller's job (see `ReaderViewModel.load()`).
@MainActor
final class ReaderPreferencesStore {
    private(set) var preferences: ReaderPreferences

    private let repository: any ScoreLibraryRepository
    private let scoreItemID: ScoreItem.ID
    /// Handles for persistence writes that have not finished. Every mutation awaits its own write before returning, so
    /// these are only ever writes some OTHER task started — which is exactly what a caller about to re-read the row
    /// (`flushPendingWrites()` then `loadOrSeed`) has to let land first, or it would read a value an in-flight write
    /// is about to overwrite. A LIST rather than one handle: joining only the latest would let an earlier, still
    /// running write land after the re-read (review Minor 2).
    private var pendingWrites: [Task<Void, Never>] = []

    /// Answers whether the Editor currently has a part edit whose preferences migration has not settled — the window
    /// in which this store must not write, because the row and this process disagree about what a part index means.
    /// Wired by `ReaderViewModel`; the default (never held) is right for a Reader with no editing host behind it.
    var isMigrationPending: @MainActor () -> Bool = { false }

    /// Mutations held back while `isMigrationPending()` was true, in the order they arrived. Re-run against the
    /// reloaded row once the hold lifts — see `applyDeferredMutations()`.
    private var deferredMutations: [(inout ReaderPreferences) -> Void] = []

    init(
        scoreItemID: ScoreItem.ID,
        repository: any ScoreLibraryRepository,
    ) {
        self.scoreItemID = scoreItemID
        self.repository = repository
        // Placeholder until `loadOrSeed` runs. Every Optional field stays `nil` — an untouched score must not look
        // touched just because the Reader stood a store up for it.
        preferences = ReaderPreferences(scoreItemID: scoreItemID, hiddenStaves: [])
    }

    /// Loads the persisted preferences if any, otherwise seeds a fresh value. Either way the resolved value lands in
    /// `preferences` and is returned for the caller to distribute into sub-models. A seed is written through only when
    /// it actually records something (see `reconcilingAuthoredHidden`) — a row that says nothing but "defaults" would
    /// make every score the user merely opened look like one they configured.
    ///
    /// `authoredHiddenStaves` are the staves the score file authored as hidden (MuseScore `<Part><show>0</show>`, via
    /// `Score.authoredHiddenStaffAddresses`). They open hidden by default: a brand-new row seeds them directly, and a
    /// row created before this feature is back-filled with them ONCE (unioned with anything the user already hid) and
    /// then marked seeded. On every subsequent open the stored `hiddenStaves` wins, so a staff the user reveals stays
    /// revealed — but `authoredHiddenStaves` is refreshed and rewritten whenever it disagrees with the score, keeping
    /// the provenance correct across re-reads that renumber staves.
    ///
    /// Because of that refresh, `authoredHiddenStaves` must only ever be the *known* authored set: passing `[]` for a
    /// notation score whose parse failed or is incomplete would permanently reclassify its authored-hidden staves as
    /// user-hidden. Callers with no notation score at all (PDFs) pass the empty default legitimately. See the caller
    /// contract on `ReaderPreferences.reconcilingAuthoredHidden`.
    /// Returns `nil` when the LOAD ITSELF FAILED, which is not the same as there being no row: a failed load must
    /// not mint a fresh value, because the caller would then distribute defaults over whatever the sub-models are
    /// holding — and on the part-remap reload path that means wiping a row the Editor has just migrated on the
    /// strength of one unlucky read (review Minor 3). "No row" is still `nil` from the repository and still seeds.
    @discardableResult
    func loadOrSeed(authoredHiddenStaves: Set<StaffAddress> = []) async -> ReaderPreferences? {
        let stored: ReaderPreferences?
        do {
            stored = try await repository.loadReaderPreferences(for: scoreItemID)
        } catch {
            return nil
        }
        // `reconcilingAuthoredHidden` is the shared iOS/Android rule.
        let (resolved, shouldPersist) = ReaderPreferences.reconcilingAuthoredHidden(
            stored: stored,
            authoredHiddenStaves: authoredHiddenStaves,
            scoreItemID: scoreItemID,
        )
        preferences = resolved
        if shouldPersist {
            await persist(resolved)
        }
        return resolved
    }

    /// Waits for every write started elsewhere to land. Call it before re-reading the row from the repository — see
    /// `pendingWrites`.
    ///
    /// Loops rather than joining once: a write can start while this is awaiting an earlier one (the awaits are real
    /// suspension points and other tasks run in them), and a handle added after the join would land after the
    /// re-read — exactly the interleaving the flush exists to rule out.
    func flushPendingWrites() async {
        while !pendingWrites.isEmpty {
            let inFlight = pendingWrites
            pendingWrites = []
            for write in inFlight {
                await write.value
            }
        }
    }

    /// Writes through the repository, leaving the handle behind so `flushPendingWrites()` can join it.
    ///
    /// `do` / `catch` rather than `try?` so the closure's result type is `Void` and the handle is a
    /// `Task<Void, Never>` — `try?` on a `Void`-returning call makes the single-expression body return `Void?`. The
    /// error is swallowed either way, exactly as it was before: preferences are a convenience, not data the user
    /// typed.
    private func persist(_ preferences: ReaderPreferences) async {
        // Every writer respects the hold, this one included. `loadOrSeed`'s authored-visibility refresh reaches here
        // without going through `mutate`, and it is a part-indexed write like any other — a `hiddenStaves` /
        // `authoredHiddenStaves` rewrite — so letting it through would have been the one hole left in the hold.
        // Skipped rather than queued: `reconcilingAuthoredHidden` re-derives the refresh from the score every time
        // it runs, so a skipped one is simply re-attempted on the next open or reload, with no state to carry.
        guard !isMigrationPending() else { return }
        let write = Task { [repository] in
            do {
                try await repository.saveReaderPreferences(preferences)
            } catch {}
        }
        pendingWrites.append(write)
        await write.value
        pendingWrites.removeAll { $0 == write }
    }

    /// Re-runs whatever `mutate` held back, against the row as it stands NOW — which on the normal path is the
    /// migrated row, already redistributed into the sub-models the held closures read from.
    ///
    /// That redistribution is what makes this safe rather than clever. A change made inside the hold window was
    /// stamped in a numbering the row had not reached, and there is no honest way to tell which of the addresses the
    /// sub-model is holding are old and which are new — so the migrated row wins and the in-window change is
    /// superseded rather than guessed at. What this call guarantees is that the row and the sub-models agree
    /// afterwards, and that nothing is ever written in a numbering that no longer applies.
    ///
    /// **The user sees that supersession.** The sub-model drove the UI the moment they touched the control — the
    /// staff they revealed is already back on screen — and the re-seed puts it where the migrated row says, so the
    /// toggle visibly snaps back a moment later. That is the honest outcome of the two-writer arrangement rather
    /// than a glitch to paper over, and it is the concrete thing the single-writer refactor would remove.
    ///
    /// The queue is bounded by **the next release**, not by one hold window: overlapping part edits keep the hold up
    /// (`releasePartMappingHoldIfSettled`), so writes held across several of them all come out together here.
    func applyDeferredMutations() async {
        guard !deferredMutations.isEmpty else { return }
        let held = deferredMutations
        deferredMutations = []
        for apply in held {
            await mutate(apply)
        }
    }

    /// Throws the held writes away without running them, for the one path that has no migrated row to re-run them
    /// against — see `ReaderViewModel.wirePartRemapReload`'s no-score bail. Keeping them would mean writing a
    /// numbering nothing has reconciled; running them later against a score that has since been reloaded from disk
    /// would be worse still.
    func discardDeferredMutations() {
        deferredMutations = []
    }

    /// Applies `apply` to a working copy, then re-seats through `ReaderPreferences.init` so clamping rules
    /// always run. The normalized value lands in `preferences` and is persisted.
    ///
    /// **Held while a part-index migration is in flight.** This is the one choke point every Reader-side write of
    /// the row goes through, which is what makes the hold total: the sub-models' `onChange` hooks, the inspector,
    /// the instruments sheet's visibility switch and the PDF re-read path all arrive here. During the window the
    /// closure is queued instead of run — not run-and-not-persisted — so `preferences` never takes on a value the
    /// row will not be given, and `applyDeferredMutations()` re-runs it against the reloaded row afterwards.
    /// `@escaping` because a held mutation outlives this call — it is queued and re-run later.
    func mutate(_ apply: @escaping (inout ReaderPreferences) -> Void) async {
        guard !isMigrationPending() else {
            deferredMutations.append(apply)
            return
        }
        var copy = preferences
        apply(&copy)
        let normalized = ReaderPreferences(
            id: copy.id,
            scoreItemID: copy.scoreItemID,
            staffSize: copy.staffSize,
            hiddenStaves: copy.hiddenStaves,
            authoredHiddenStaves: copy.authoredHiddenStaves,
            stripProgramOverrides: copy.stripProgramOverrides,
            stripVolumeOverrides: copy.stripVolumeOverrides,
            staffClefOverrides: copy.staffClefOverrides,
            tempoMultiplier: copy.tempoMultiplier,
            honorLayoutBreaks: copy.honorLayoutBreaks,
            repeatMode: copy.repeatMode,
            abRepeat: copy.abRepeat,
            masterVolume: copy.masterVolume,
            transposeSemitones: copy.transposeSemitones,
            a4ReferenceHz: copy.a4ReferenceHz,
            hasSeededAuthoredVisibility: copy.hasSeededAuthoredVisibility,
        )
        preferences = normalized
        await persist(normalized)
    }
}
