import Domain
import Foundation
import Library
import Reader
import SwiftUI
import UtilityCore

/// One Mac score window: the reader fills it, and nothing else is in it. The library is its own single-instance
/// `Window` scene now (`MacWindowID.library`), so this view has no sidebar, no split view and no library rows — see
/// the design spec §2.1 for why the two could not share a window.
///
/// Every score window comes from the same `WindowGroup(for: MacWindowScore.self)`, and `MacWindowTabAssist` in the
/// background gives them all one AppKit tabbing identity so macOS can group them as tabs.
struct MacShellView: View {
    let bootstrap: AppBootstrap
    /// The window's own identity value, as `WindowGroup(for: MacWindowScore.self)` presents it. Taken by value, not
    /// as a `Binding`: a window's score is fixed the moment `openWindow(value:)` mints it, because opening a score
    /// is now opening a *window* rather than swapping a detail column's content, so nothing here ever writes it back.
    let window: MacWindowScore?
    /// The process's one `LibraryViewModel`, owned by `FolinoMacApp`. This window needs it for exactly one thing:
    /// publishing File ▸ Import as a focused scene value, so the menu command still works while a score window is
    /// key. `@FocusedValue` follows *scene* focus, so the browser window's own publication is invisible from here —
    /// a score window has to publish its own, and it has to be the same view model the browser is watching.
    let libraryVM: LibraryViewModel
    @Environment(\.openWindow) private var openWindow

    /// The one adapter this view reads itself, unwrapped once in `init` (see the guard there for why it is
    /// guaranteed non-nil) rather than at every use site: `openScoreItem` resolves the window's id against it. The
    /// reader's other adapters are `MacEditableReaderScreen`'s business now, and it unwraps them the same way.
    private let repository: any ScoreLibraryRepository

    /// The score this window is showing, read out of the window's identity value.
    private var scoreID: ScoreItem.ID? {
        window?.scoreID
    }

    init(bootstrap: AppBootstrap, window: MacWindowScore?, libraryVM: LibraryViewModel) {
        self.bootstrap = bootstrap
        self.window = window
        self.libraryVM = libraryVM
        // Every adapter read below is guaranteed non-nil here: `FolinoMacApp` only builds `MacShellView` once
        // `bootstrap.isReady` is true, and `AppBootstrap.start()` populates all of them synchronously before it
        // flips that flag (see the `Task { [weak self] in await self?.finishStartup(...) }` at the end of `start()`
        // — everything above that line already ran).
        guard let repository = bootstrap.repository else {
            fatalError("MacShellView built before AppBootstrap finished starting")
        }
        self.repository = repository
    }

    var body: some View {
        content
            .frame(minWidth: 900, minHeight: 600)
            .background(MacWindowTabAssist())
            .focusedSceneValue(\.macLibraryImportAction, importAction)
            // A score window must open what its own File ▸ Import brought in, even with the browser closed — see
            // `ImportedScoreOpener`. The browser installs the same watcher; `MacImportedScoreClaim` is what stops
            // them from opening the score twice.
            .opensImportedScores(from: libraryVM)
    }

    /// File ▸ Import while THIS window is key — and the reason it is not just `await libraryVM.startImport(from:)`.
    ///
    /// **Both of the import flow's alerts have exactly one host in the whole app, and it is the browser.**
    /// `ImportErrorAlert` and `DuplicateImportAlert` are mounted only by `libraryRootPresentations`, applied only by
    /// `MacLibraryBrowser`. A score window mounts neither, so importing a duplicate (or a corrupt file) from here
    /// with the browser closed used to arm `duplicatePrompt` / `currentError` with nothing on screen to answer them:
    /// the import silently stalled, the flag stayed set, and the next ⌘O opened the browser already presenting an
    /// alert about a file imported who-knows-when.
    ///
    /// **The arbitration decision: one host, summoned — not a second host, guarded.** Mounting the presentations
    /// here too would put two hosts on one process-wide `@Observable`, and every guard that could keep them from
    /// both presenting (key-window state, a claim token) is a *timing* argument — the same class of reasoning
    /// `openImportedScore`'s measurements say not to trust, and worse here because an alert's presentation binding
    /// is re-evaluated on every body pass rather than fired once. A key-window guard is actively hazardous: an
    /// alert is its own key window on macOS, so the guard would flip false while the alert is up, and the binding's
    /// `set(false)` would clear the very error it is showing. So there is still exactly ONE mount point, and two
    /// simultaneous alerts are structurally impossible rather than merely unlikely — no code path can produce a
    /// second one, because no second one exists.
    ///
    /// What this adds is only the summons: after the import settles, if it left a prompt armed, bring the single
    /// host forward. `openWindow(id:)` on a `Window` scene focuses the existing instance or creates the one
    /// instance, and the browser's first body pass reads `duplicatePrompt != nil` and presents — the same
    /// evaluate-on-appear behavior that produced the stale-alert bug, used deliberately. Nothing is summoned on the
    /// ordinary path: a clean import sets `pendingScoreToOpen`, which `opensImportedScores` turns into a score
    /// window without the browser ever appearing.
    ///
    /// One state write is not at issue here: this runs from `NSOpenPanel`'s completion (`MacCommands`), not from
    /// inside a SwiftUI update, and `openWindow` is the only call it makes.
    private func importAction(_ url: URL) async {
        await libraryVM.startImport(from: url)
        guard libraryVM.hasPendingImportPrompt else { return }
        openWindow(id: MacWindowID.library)
    }

    @ViewBuilder
    private var content: some View {
        if let item = openScoreItem {
            // `id(item.id)` so switching the window to another score builds a fresh `MacEditableReaderScreen` — and
            // with it a fresh `ReaderViewModel`, `ReaderEditingHost` and `EditorViewModel`, each created once per
            // screen instance in a `@State`.
            MacEditableReaderScreen(item: item, bootstrap: bootstrap)
                .id(item.id)
                .toolbar {
                    ToolbarItem(placement: .navigation) {
                        Button {
                            openWindow(id: MacWindowID.library)
                        } label: {
                            Label {
                                Text("mac.toolbar.showLibrary")
                            } icon: {
                                Image(systemName: "square.grid.2x2")
                            }
                        }
                    }
                }
        } else {
            // No score chosen yet — or the window's `scoreID` names a row the library holds neither live nor in the
            // trash (permanently deleted, or a restored window value that outlived its score). Both read as an empty
            // window. A soft-deleted score is NOT this case; see `openScoreItem`.
            ContentUnavailableView {
                Label {
                    Text("app.detail.empty.title")
                } icon: {
                    Image(systemName: "music.note")
                }
            }
        }
    }

    /// The `ScoreItem` this window's `scoreID` names. Two things only: the reader is built from the current row
    /// rather than a stale copy, and a `scoreID` no row carries at all yields `nil` and an empty window. It does NOT
    /// push later edits into a reader that is already open — `MacReaderRootScreen` seeds its view model once per
    /// `.id(item.id)`, and a title edit does not change the id.
    ///
    /// **`deletedScoreItems` is searched too, and that fallback is load-bearing.** `scoreItems` excludes soft-deleted
    /// rows, so a live-rows-only lookup made every Open path in Recently Deleted — the row menu's Open, Return, and
    /// double-click — mint a permanently empty window: the id resolved to nothing, and the
    /// empty branch below carries no toolbar, so not even the library button was there to get back with. iOS opens a
    /// deleted score fine (`App/iOS/AppShellView.swift`'s `onOpenScore` is handed the `ScoreItem` itself, never an
    /// id to re-resolve), and behavior matches iOS; the Mac carries an id because a window's identity has to be
    /// `Codable` for restoration, which is a storage detail and not a reason to diverge. A soft-deleted row still
    /// has its file on disk — that is what makes Restore possible — so the reader opens it exactly as it opens any
    /// other.
    private var openScoreItem: ScoreItem? {
        guard let scoreID else { return nil }
        return repository.scoreItems.first { $0.id == scoreID }
            ?? repository.deletedScoreItems.first { $0.id == scoreID }
    }
}
