import Domain
import Foundation
import Library
import LicenseList
import ScoreFiles
import Settings
import SwiftUI
import UtilityCore

/// The value that identifies one of `FolinoMacApp`'s score windows, and what `WindowGroup(for:)` dedupes on. `scoreID`
/// alone isn't enough: `WindowGroup(for:)` reuses (refocuses) an existing window that already presents an equal
/// value rather than opening a second one, so `openWindow(value:)` with a bare `ScoreItem.ID` would make
/// `MacCommands`'s "Open in New Tab" a no-op whenever the score is already showing in the frontmost window.
/// `tabInstance` exists purely to make every fresh "Open in New Tab" invocation compare unequal to every window
/// already open, guaranteeing a new window every time — it plays no other role and is never read back.
struct MacWindowScore: Hashable, Codable {
    var scoreID: ScoreItem.ID
    var tabInstance = UUID()
}

/// The ids `openWindow(id:)` addresses. There is exactly one, because there is exactly one kind of window that is not
/// a score: the library browser, a single-instance `Window` scene. Score windows are addressed by *value*
/// (`openWindow(value: MacWindowScore(...))`) through the `WindowGroup(for:)` above, never by id.
enum MacWindowID {
    static let library = "library"
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
    @State private var bootstrap = AppBootstrap()
    /// The process's one and only `LibraryViewModel`, shared by the browser window and by every score window's
    /// File ▸ Import.
    ///
    /// **One instance per process, not one per window.** `pendingScoreToOpen` is set on whichever instance ran the
    /// import, and the watcher that consumes it lives in the browser window — so a score window importing through
    /// its own instance would queue a score nothing was watching for.
    ///
    /// It is `Optional` because it cannot exist before `AppBootstrap` has produced the adapters it is built from.
    /// `startAppServices()` fills it in the same turn `bootstrap.start()` returns, and every scene unwraps it
    /// together with `bootstrap.isReady`, so neither can outrun the other.
    @State private var libraryVM: LibraryViewModel?
    @State private var columnVisibility: NavigationSplitViewVisibility = .doubleColumn
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
        .commands { MacCommands(columnVisibility: $columnVisibility) }

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

/// The library window's content: the browser, plus the post-import watcher that used to live on `MacShellView`.
///
/// A view rather than inline scene content because both halves need a view context — `@Environment(\.openWindow)`
/// and `onChange`.
private struct MacLibraryWindowContent: View {
    let viewModel: LibraryViewModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        MacLibraryBrowser(
            viewModel: viewModel,
            // `onOpenScore` and `onOpenScoreInNewWindow` have identical bodies today, and that is not an oversight:
            // opening a score is always `openWindow(value:)`, and whether the new window lands as a *tab* of the
            // existing score windows or as a standalone one is decided by AppKit, from the tabbing identity
            // `MacWindowTabAssist` gives every score window and the user's "Prefer tabs" system setting. Neither call
            // site can force it. They stay two closures so the distinction has a home the day the app can act on it.
            onOpenScore: { item in openWindow(value: MacWindowScore(scoreID: item.id)) },
            onOpenScoreInNewWindow: { item in openWindow(value: MacWindowScore(scoreID: item.id)) },
            // PARITY(macos): playlist context in the reader — the `PlaylistID` is dropped here because
            //   `MacWindowScore` carries a score id and nothing else, so `MacReaderRootScreen` opens the score
            //   standalone and the playlist's continuation control and end-of-score auto-advance are unreachable.
            //   Threading a `PlaylistID` through `MacWindowScore` is what closes it. (Moved here from
            //   `MacShellView.sidebar`, which no longer exists — the gap did not close, its call site did.)
            onOpenInPlaylist: { item, _ in openWindow(value: MacWindowScore(scoreID: item.id)) },
        )
        .onChange(of: viewModel.pendingScoreToOpen?.id) { _, newID in
            // Mirrors `AppShellView.ReadyShell`'s watcher: a successful import (File ▸ Import, or a drag onto the
            // browser) opens the new score, same as iOS — in a score window, because that is where scores live now.
            guard let newID,
                  let item = viewModel.pendingScoreToOpen,
                  item.id == newID else { return }
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
    /// The hop is safe for `pendingScoreToOpen` specifically: the only reader is the watcher above, which is keyed on
    /// the id changing, so a value that stays set for one hop cannot re-trigger anything.
    private func openImportedScore(_ item: ScoreItem) {
        openWindow(value: MacWindowScore(scoreID: item.id))
        Task { @MainActor in
            viewModel.pendingScoreToOpen = nil
        }
    }
}
