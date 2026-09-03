import Domain
import Foundation
import Library
import LicenseList
import ScoreFiles
import Settings
import SwiftUI
import UtilityCore

/// The value that identifies one of `FolinoMacApp`'s score windows, and what `WindowGroup(for:)` dedupes on.
///
/// **The score id, and nothing else — deliberately.** `WindowGroup(for:)` refocuses an existing window whose
/// presented value equals the one passed to `openWindow(value:)`, so opening a score that is already open brings its
/// window (or tab) forward instead of minting a second one. That is MuseScore 4's rule (`ProjectActionsController::
/// openProject` step 3, `activateWindowWithProject`) and the design's (`2026-09-02-macos-edit-session-design.md` §3):
/// with the score always editable, a second window on the same score would be a second editor of one file.
struct MacWindowScore: Hashable, Codable {
    var scoreID: ScoreItem.ID
}

/// The ids `openWindow(id:)` addresses. There is exactly one, because there is exactly one kind of window that is not
/// a score: the library browser, a single-instance `Window` scene. Score windows are addressed by *value*
/// (`openWindow(value: MacWindowScore(...))`) through the `WindowGroup(for:)` above, never by id.
enum MacWindowID {
    static let library = "library"
}

/// The single-owner guard behind `opensImportedScores(from:)`: it decides which of the several windows watching
/// `LibraryViewModel.pendingScoreToOpen` is the one that actually opens the score.
///
/// **Why a guard is needed at all.** Every window scene installs the watcher (it must — either window kind can start
/// an import, and either can be closed), so one `pendingScoreToOpen` can be seen by the browser plus every open score
/// window. Without arbitration each of them would call `openWindow(value:)` and the user would get N windows for one
/// import.
///
/// **Why this arbitration is correct.** All watchers run on the main actor, and all of them observe the same value,
/// so for a given id they run in the same update pass — before the `nil` that clears it, which is deferred by one
/// main-actor hop. The first to arrive stores the id and returns `true`; every later one compares equal and gets
/// `false`. Ordering between windows does not matter, only that one of them is first. A watcher installed *late*
/// (a window opened after the value was set) never fires for it at all, since `onChange` reports changes, not the
/// current value.
///
/// **Why it is keyed on the id and released on `nil` rather than latched.** `ImportDecision.openExisting` makes
/// `commitImport` return the score that was already in the library, so two separate imports of the same file
/// genuinely can publish the *same* `ScoreItem.ID`. A latch on the id alone would silently refuse the second one.
/// Releasing on the `nil` transition — which every watcher sees, one hop after the open — keeps the invariant
/// "`claimedID` is non-nil exactly while one open is in flight" instead.
///
/// **This is deliberately not SwiftUI state.** A `@State` bookkeeping write is precisely the second write that
/// `ImportedScoreOpener.openImportedScore`'s measurements forbid. A `static var` on a plain enum invalidates no view
/// and schedules no update, so it is not a write in the sense those measurements are about — but that reasoning is
/// exactly the kind the measurement's own closing note says not to trust, so it is on the QA sheet to re-measure.
@MainActor
enum MacImportedScoreClaim {
    private static var claimedID: ScoreItem.ID?

    /// `true` for the first watcher to offer `id`, `false` for every later one until `release()`.
    static func claim(_ id: ScoreItem.ID) -> Bool {
        guard claimedID != id else { return false }
        claimedID = id
        return true
    }

    static func release() {
        claimedID = nil
    }
}

/// The Mac app's entry point. Drives the real `AppBootstrap` and reports its state — a spinner while it runs, then
/// the content or the failure.
///
/// **A window is a score, or it is the library — never both.** `WindowGroup(for: MacWindowScore.self)` supplies every
/// score window (and macOS's automatic tabbing along with it — see `MacWindowTabAssist`); the single-instance
/// `Window` scene below is the library browser. `Settings` is its own scene, as it must be. See the design spec §2.1
/// for why the previous arrangement — one split-view window holding both — could not stay.
@main
struct FolinoMacApp: App {
    @NSApplicationDelegateAdaptor(MacAppDelegate.self) private var appDelegate
    @State private var bootstrap = AppBootstrap()
    /// The process's one and only `LibraryViewModel`, shared by the browser window and by every score window's
    /// File ▸ Import.
    ///
    /// **One instance per process, not one per window.** `pendingScoreToOpen` is set on whichever instance ran the
    /// import, and every window watches it (`opensImportedScores(from:)`) — so a window importing through its own
    /// instance would queue a score none of those watchers could see.
    ///
    /// It is `Optional` because it cannot exist before `AppBootstrap` has produced the adapters it is built from.
    /// `startAppServices()` fills it in the same turn `bootstrap.start()` returns, and every scene unwraps it
    /// together with `bootstrap.isReady`, so neither can outrun the other.
    @State private var libraryVM: LibraryViewModel?
    /// Owns the "mark this version's history as seen" bookkeeping for `SettingsSheet`'s About section, mirroring
    /// `App/iOS/AppShellView.swift`'s `versionHistoryPresenter`. The cold-launch "show what's new" sheet iOS also
    /// drives from this type is a separate, larger feature (its own presentation host wired into the window
    /// lifecycle) that nothing here has asked for yet — this only supplies the one method Settings needs.
    @State private var versionHistoryPresenter = VersionHistoryPresenter()

    init() {
        EdwinFontLoader.registerOnce()
    }

    var body: some Scene {
        WindowGroup(for: MacWindowScore.self) { $window in
            Group {
                if bootstrap.isReady, let libraryVM {
                    MacShellView(bootstrap: bootstrap, window: window, libraryVM: libraryVM)
                } else if let failure = bootstrap.failure {
                    bootstrapFailure(failure)
                } else {
                    ProgressView()
                }
            }
            .task { startAppServices() }
        }
        .commands {
            AppCommandMenus()
        }
        // **Measured, on the first launch anyone was able to observe.** `.defaultLaunchBehavior(.presented)` on the
        // library `Window` below is not enough on its own: a `WindowGroup` is the default launch scene because it is
        // `body`'s first, and it won — the app came up showing one empty score window and no browser at all, which is
        // worse than the stray extra window that was predicted. That window has no toolbar either (the library button
        // lives inside `MacShellView`'s `if let item` branch), so the only way back was ⌘O, undiscoverable.
        //
        // Suppressing the group does not stop `openWindow(value:)` from creating score windows; it only stops one
        // being minted at launch with nothing to show.
        .defaultLaunchBehavior(.suppressed)

        // `Text(verbatim:)` rather than a string key: `folino` is the brand, written lowercase wherever a user can
        // read it, and it is never translated — a `LocalizedStringKey` here would mint a catalog entry that must
        // stay untranslated in every language.
        Window(Text(verbatim: "folino"), id: MacWindowID.library) {
            Group {
                if bootstrap.isReady, let libraryVM {
                    MacLibraryWindowContent(viewModel: libraryVM)
                } else if let failure = bootstrap.failure {
                    bootstrapFailure(failure)
                } else {
                    ProgressView()
                }
            }
            .task { startAppServices() }
        }
        // macOS 15+, and the deployment floor is exactly 15.0, so this needs no availability guard. It is what makes
        // a fresh launch present the browser rather than leaving the user with whatever the score `WindowGroup`
        // restored (or an empty score window).
        .defaultLaunchBehavior(.presented)

        Settings {
            SettingsSheet(
                provider: bootstrap.museScoreGeneralProvider,
                onVersionHistoryViewed: { versionHistoryPresenter.markCurrentVersionAsSeen() },
                crashReporter: bootstrap.crashReporter ?? NoopCrashReporter(),
                analytics: bootstrap.analytics ?? NoopAnalytics(),
            ) {
                LicenseListView()
            }
            .frame(minWidth: 480, idealWidth: 560, minHeight: 420, idealHeight: 560)
        }
    }

    /// The bootstrap failure state, shown identically by both window scenes.
    private func bootstrapFailure(_ failure: Error) -> some View {
        ContentUnavailableView {
            Text("app.bootstrap.error.title")
        } description: {
            Text((failure as? LocalizedError)?.errorDescription ?? failure.localizedDescription)
        }
    }

    /// `bootstrap.start()` plus the one `LibraryViewModel` both window scenes read. Driven from a `.task` in each
    /// scene because either can be the first to appear — the browser at launch, a score window on restoration — and
    /// both halves are idempotent: `start()` latches on its own `didStart`, and the view model is built only while
    /// it is still `nil`.
    private func startAppServices() {
        bootstrap.start()
        guard libraryVM == nil else { return }
        // Every adapter read below is non-nil by the time `start()` has returned: it populates all of them
        // synchronously before flipping `isReady` (see the `Task { [weak self] in await self?.finishStartup(...) }`
        // at the end of `start()` — everything above that line already ran). The one case where they are not is the
        // one where `start()` threw, and then `bootstrap.failure` is set and both scenes are showing the failure
        // view instead — which is why this returns rather than trapping.
        guard let repository = bootstrap.repository,
              let importer = bootstrap.importer,
              let gateway = bootstrap.gateway,
              let originalStore = bootstrap.originalStore,
              let shareService = bootstrap.shareService,
              let metadataReader = bootstrap.metadataReader
        else { return }
        libraryVM = LibraryViewModel(
            repository: repository,
            originalStore: originalStore,
            importer: importer,
            gateway: gateway,
            shareService: shareService,
            metadataReader: metadataReader,
            creator: LiveScoreFileCreator(
                gateway: gateway,
                repository: repository,
                scoresDirectory: AppPaths.scoresDirectory,
            ),
            scoresDirectory: AppPaths.scoresDirectory,
            analytics: bootstrap.analytics ?? NoopAnalytics(),
            crashReporter: bootstrap.crashReporter ?? NoopCrashReporter(),
        )
    }
}

/// The library window's content.
///
/// A view rather than inline scene content because it needs a view context: `@Environment(\.openWindow)`,
/// `@Environment(\.dismissWindow)`, the imported-score watcher, and the focused value below all require one.
private struct MacLibraryWindowContent: View {
    let viewModel: LibraryViewModel
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
    /// The library window has no editor, but File ▸ Show Library / Import still have to work while it is key — and
    /// on a fresh launch with an empty library it is the only import route the app has at all. Created once (not
    /// computed in `body`) so every pass publishes the same object — see `AppCommandContext`.
    @State private var commandContext = AppCommandContext(editor: nil, host: nil)
    /// Raised by the bare `Z` row while the library is key — spec §7's install table names this window (not
    /// `MacShellView`'s transient empty-window branch) as the real "no score open" surface, since a score window
    /// never shows an empty state for longer than one main-actor hop.
    @State private var isSearching = false

    var body: some View {
        MacLibraryBrowser(
            viewModel: viewModel,
            onOpenScore: { openScore($0.id) },
            // PARITY(macos): playlist context in the reader — the `PlaylistID` is dropped here because
            //   `MacWindowScore` carries a score id and nothing else, so `MacReaderRootScreen` opens the score
            //   standalone and the playlist's continuation control and end-of-score auto-advance are unreachable.
            //   Threading a `PlaylistID` through `MacWindowScore` is what closes it. (Moved here from
            //   `MacShellView.sidebar`, which no longer exists — the gap did not close, its call site did.)
            onOpenInPlaylist: { item, _ in openScore(item.id) },
        )
        // §2.9.2 — the library is summoned *over* the score window, on the same Space, full screen included.
        .background(MacLibraryWindowPresentation())
            // `@FocusedValue` follows scene focus, so a score window publishing `appCommandContext` does nothing
            // for the browser; the browser has to publish its own.
            .focusedSceneValue(\.appCommandContext, commandContext)
            // Bare-key delivery for this window too (design note in `AppCommandKeyMap`) — with no editor, only the
            // non-mutating, editor-independent rows (today: just `app.search`) can ever be enabled here.
            .background(AppCommandKeyMap(target: commandContext))
            .sheet(isPresented: $isSearching) {
                CommandSearchSheet(context: commandContext, isPresented: $isSearching)
            }
            .onAppear {
                commandContext.showLibrary = { openWindow(id: MacWindowID.library) }
                commandContext.importScore = {
                    MacCommandContextWiring.presentImportPanel { url in await viewModel.startImport(from: url) }
                }
                commandContext.presentSearch = { isSearching = true }
            }
            .opensImportedScores(from: viewModel)
    }

    /// §2.9.1 — the library is a chooser: choosing a score opens its window and closes this one, in one gesture.
    ///
    /// **The dismiss is deferred by one main-actor hop, and the open is not.** These closures are reached from
    /// `contextMenu(forSelectionType:primaryAction:)`, from `onKeyPress`, and from a context-menu button — an event
    /// handler in the first two cases, but SwiftUI does not promise that no update is in flight when one runs, and
    /// `ImportedScoreOpener.openImportedScore`'s measurements say two window-scene writes in one such handler are
    /// what faults `NavigationRequestObserver`. Keeping the shape those measurements cover costs one turn of the
    /// library staying up behind the new window, which is invisible.
    ///
    /// **Import and the new-score wizard deliberately do not do this.** §2.9.1 names double-click, Return and the
    /// row's Open item; those routes go through `LibraryViewModel.pendingScoreToOpen` and `ImportedScoreOpener`
    /// instead, whose handler genuinely does run inside an update and whose write count is the one measured hazard
    /// in this file. Importing from the browser leaves the browser behind the new score window.
    private func openScore(_ id: ScoreItem.ID) {
        openWindow(value: MacWindowScore(scoreID: id))
        Task { @MainActor in
            dismissWindow(id: MacWindowID.library)
        }
    }
}

/// Opens whatever `LibraryViewModel.pendingScoreToOpen` names, in a score window.
///
/// **Installed in every window scene, because every window can start an import and every window can be closed.**
/// File ▸ Import is published by the browser *and* by each score window; the browser's drag-and-drop drop target and
/// its new-score wizard start imports too. Parking one watcher in the browser would lose every import made while it
/// is closed (and `onChange` does not fire for a value that was already set when the window reopens), while parking
/// it in a score window loses the browser's own routes.
///
/// **Why the watcher and not the initiator.** The plan's preferred shape was "whoever starts an import opens its
/// result", which would need `startImport` to hand its caller the score. It does not, and cannot be made to without
/// changing `LibraryViewModel`'s contract: it returns `Void`, and on the duplicate path it returns *before* the
/// import is committed at all (it only sets `duplicatePrompt`; the user's later choice runs `commit`, which is what
/// sets `pendingScoreToOpen`). Two further setters — the new-score wizard's `createScore(from:)` and that same
/// post-prompt `commit` — run inside the Library module with no initiator closure to call back into. So
/// `pendingScoreToOpen` genuinely is the only channel, and the arbitration moves into `MacImportedScoreClaim`
/// instead — see its doc comment for why exactly one watcher acts.
private struct ImportedScoreOpener: ViewModifier {
    let viewModel: LibraryViewModel
    @Environment(\.openWindow) private var openWindow

    func body(content: Content) -> some View {
        content.onChange(of: viewModel.pendingScoreToOpen?.id) { _, newID in
            // Mirrors `AppShellView.ReadyShell`'s watcher: a successful import (File ▸ Import, a drag onto the
            // browser) or a newly created score opens it, same as iOS — in a score window, because that is where
            // scores live now.
            guard let newID else {
                // The clear made one hop below, seen by every watcher. Ends the claim so a later import that
                // republishes the same id is not mistaken for this one.
                MacImportedScoreClaim.release()
                return
            }
            guard let item = viewModel.pendingScoreToOpen,
                  item.id == newID,
                  MacImportedScoreClaim.claim(newID) else { return }
            openImportedScore(item)
        }
    }

    /// Opens `item` for the post-import watcher, which runs INSIDE a SwiftUI update — and that difference is the
    /// whole reason this is not two plain statements in the handler above.
    ///
    /// **Two state writes made while an update is already running re-enter the navigation observer in the same
    /// frame**, and SwiftUI logs `Update NavigationRequestObserver tried to update multiple times per frame` at FAULT
    /// level. Measured on this watcher in Ⅲb, when it lived on `MacShellView` and the window was a
    /// `NavigationSplitView`, one mode per instrumented launch:
    ///
    /// * Any ONE write alone from the handler is clean — the window's score, the split view's column visibility, or
    ///   `pendingScoreToOpen = nil` on its own. Any TWO of them together fault, in every pairing. Even a plain
    ///   `@State` bookkeeping write counts as the second one, and clearing `pendingScoreToOpen` counts because it
    ///   re-fires the very `onChange` observing it.
    /// * The same writes made where no update is in flight are clean: SwiftUI coalesces them into one update instead
    ///   of re-entering a running one.
    /// * Rearranging did not escape it. Splitting the writes across two chained `onChange`s, running the handoff from
    ///   `.task(id:)`, moving the watcher onto the sidebar column, making the column visibility per-window `@State`,
    ///   and — **this one matters, because it is the tidy-up this method invites** — moving ALL the writes into one
    ///   `Task { @MainActor }` were each built and launched, and each still faulted.
    ///
    /// **The causal model is under-determined, and the measurements are what carry this, not the rule.** "At most one
    /// write in the handler" fits every row, but it does not explain why three writes inside one deferred `Task` still
    /// fault while the same three split one-and-two do not. Do not extend the rule by reasoning — re-measure.
    ///
    /// The split view those measurements were taken on is gone from the score window, and the library browser's own
    /// split view is a different topology. **That is a reason to re-measure, not a licence to relax the shape**, so
    /// this keeps it: exactly one write here — `openWindow`, which is what puts the reader on screen and is the one
    /// that would visibly lag the import if it waited — and the clear one main-actor hop later, where nothing is
    /// updating. Re-measuring belongs to QA.
    ///
    /// The hop is safe for `pendingScoreToOpen` specifically: its only readers are these watchers, which are keyed on
    /// the id changing, so a value that stays set for one hop cannot re-trigger an open — the claim above refuses a
    /// repeat of the same id, and the `nil` this writes is what releases it.
    ///
    /// `MacImportedScoreClaim.claim` in the handler is not a second write: it touches a plain `static var`, which
    /// invalidates no view and schedules no update. See that type's doc comment.
    ///
    /// **The two deferred writes are two separate `Task`s, and that arrangement is UNMEASURED — do not read the
    /// paragraphs above as endorsing it.** `pendingOpenInEditSession` has to be disarmed somewhere — the flag is
    /// `public private(set)` and `consumePendingOpenInEditSession()` is the only call that clears it — which makes
    /// two deferred writes rather than one, and there were two ways to place them:
    ///
    /// * **One inline write + two in the single existing hop.** This is literally the "same three split
    ///   one-and-two" the measurement above records as CLEAN. It is the arrangement with evidence behind it, and it
    ///   is the one this method does NOT use.
    /// * **One inline write + two adjacent single-write `Task`s** — what is written below. Nobody has measured
    ///   this. Two adjacent unstructured `Task`s are two main-actor *turns*, and the fault is reported per *frame*;
    ///   those are not the same unit, so "two turns" does not follow from anything in the table.
    ///
    /// It is written this way because keeping every handler to one write is the invariant the whole method is
    /// built around, and it seemed the more conservative reading — but that is a preference, not a measurement, and
    /// the measured-clean alternative was available and was not taken. If QA's `NavigationRequestObserver` grep
    /// ever fires around a new-score open, collapsing these two `Task`s into the one hop is the first thing to try,
    /// because that is the shape the evidence already covers.
    private func openImportedScore(_ item: ScoreItem) {
        openWindow(value: MacWindowScore(scoreID: item.id))
        Task { @MainActor in
            viewModel.pendingScoreToOpen = nil
        }
        Task { @MainActor in
            // Consumed and dropped: the Mac has no edit mode to start in — every score window is editable.
            _ = viewModel.consumePendingOpenInEditSession()
        }
    }
}

extension View {
    /// Installs the watcher that opens an imported (or newly created) score in a score window. Every window scene
    /// gets one — see `ImportedScoreOpener` for why, and `MacImportedScoreClaim` for what keeps them from all
    /// opening the same score at once.
    func opensImportedScores(from viewModel: LibraryViewModel) -> some View {
        modifier(ImportedScoreOpener(viewModel: viewModel))
    }
}
