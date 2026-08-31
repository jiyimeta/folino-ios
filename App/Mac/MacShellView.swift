import Domain
import Foundation
import Library
import LicenseList
import Reader
import ScoreFiles
import SwiftUI
import UtilityCore

/// One Mac window: the library in the sidebar, the score in the detail column. Every window comes from the same
/// `WindowGroup`, which is what gives macOS's automatic window tabbing (⌘T, tab drag-out, Merge All Windows) for
/// free — see the design spec §3.3 for why a separate library `Window` would forfeit that.
struct MacShellView: View {
    let bootstrap: AppBootstrap
    /// The window's own identity value, as `WindowGroup(for: MacWindowScore.self)` presents it. `scoreID` below is
    /// the view over this that every other call site reads/writes — see its doc comment for why it isn't just
    /// `@Binding var scoreID: ScoreItem.ID?` directly.
    @Binding var window: MacWindowScore?
    @Binding var columnVisibility: NavigationSplitViewVisibility

    @State private var libraryVM: LibraryViewModel
    @State private var sidebarPath = NavigationPath()

    /// The adapters the detail column's reader needs, unwrapped once in `init` (see the guard there for why they are
    /// guaranteed non-nil) rather than at every use site.
    private let repository: any ScoreLibraryRepository
    private let originalStore: any ScoreOriginalStore
    private let gateway: any ScoreFileGateway
    private let shareService: any ScoreShareService
    private let metadataReader: any ScoreMetadataReading
    private let annotationCoordinator: AnnotationSaveCoordinator

    /// The score this window is showing. Reads/writes go through `window` rather than being the window's identity
    /// value directly, because that identity value also carries a `tabInstance` — see `MacWindowScore`'s doc
    /// comment. Writing here preserves this window's own `tabInstance` (it is not opening a new window, just
    /// changing what the existing one shows), while `MacCommands`'s "Open in New Tab" mints a fresh one via
    /// `openWindow(value:)` so it always creates a new window instead of refocusing this one.
    private var scoreID: ScoreItem.ID? {
        get { window?.scoreID }
        nonmutating set {
            if let newValue {
                window = MacWindowScore(scoreID: newValue, tabInstance: window?.tabInstance ?? UUID())
            } else {
                window = nil
            }
        }
    }

    init(
        bootstrap: AppBootstrap,
        window: Binding<MacWindowScore?>,
        columnVisibility: Binding<NavigationSplitViewVisibility>,
    ) {
        self.bootstrap = bootstrap
        _window = window
        _columnVisibility = columnVisibility
        // Every adapter read below is guaranteed non-nil here: `FolinoMacApp` only builds `MacShellView` once
        // `bootstrap.isReady` is true, and `AppBootstrap.start()` populates all of them synchronously before it
        // flips that flag (see the `Task { [weak self] in await self?.finishStartup(...) }` at the end of `start()`
        // — everything above that line already ran).
        guard let repository = bootstrap.repository,
              let importer = bootstrap.importer,
              let gateway = bootstrap.gateway,
              let originalStore = bootstrap.originalStore,
              let shareService = bootstrap.shareService,
              let metadataReader = bootstrap.metadataReader,
              let annotationCoordinator = bootstrap.annotationCoordinator
        else {
            fatalError("MacShellView built before AppBootstrap finished starting")
        }
        self.repository = repository
        self.originalStore = originalStore
        self.gateway = gateway
        self.shareService = shareService
        self.metadataReader = metadataReader
        self.annotationCoordinator = annotationCoordinator
        _libraryVM = State(
            wrappedValue: LibraryViewModel(
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
            ),
        )
    }

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            sidebar
                .navigationSplitViewColumnWidth(min: 260, ideal: 320)
        } detail: {
            detail
        }
        .frame(minWidth: 900, minHeight: 600)
        .focusedSceneValue(\.macLibraryImportAction) { url in await libraryVM.startImport(from: url) }
        .focusedCurrentScoreID(scoreID)
        .onChange(of: libraryVM.pendingScoreToOpen?.id) { _, newID in
            // Mirrors `AppShellView.ReadyShell`'s watcher: a successful import (File ▸ Import, or a drag onto the
            // sidebar) jumps straight to the new score, same as iOS.
            guard let newID,
                  let item = libraryVM.pendingScoreToOpen,
                  item.id == newID else { return }
            openImportedScore(item)
        }
    }

    /// Show `item` in this window and put the sidebar behind it. What the two user-driven callers — a click in the
    /// library and a playlist open — mean by "open this score here".
    ///
    /// Both are button actions, so they run OUTSIDE any SwiftUI update and the two writes coalesce into a single
    /// update. The post-import watcher does not have that luxury; see `openImportedScore`.
    private func openScore(_ item: ScoreItem) {
        scoreID = item.id
        columnVisibility = .detailOnly
    }

    /// `openScore` for the post-import watcher, which runs INSIDE a SwiftUI update — and that difference is the whole
    /// reason this method exists.
    ///
    /// **Two state writes made while an update is already running re-enter the split view's navigation observer in the
    /// same frame**, and SwiftUI logs `Update NavigationRequestObserver tried to update multiple times per frame` at
    /// FAULT level. Measured on this watcher, one mode per instrumented launch:
    ///
    /// * Any ONE write alone from the handler is clean — `scoreID`, `columnVisibility`, or
    ///   `pendingScoreToOpen = nil` on its own. Any TWO of them together fault, in every pairing. Even a plain
    ///   `@State` bookkeeping write counts as the second one, and clearing `pendingScoreToOpen` counts because it
    ///   re-fires the very `onChange` observing it.
    /// * The same writes made where no update is in flight are clean, which is why `openScore`'s two callers never
    ///   trigger it: SwiftUI coalesces them into one update instead of re-entering a running one.
    /// * Rearranging does not escape it. Splitting the writes across two chained `onChange`s, running the handoff
    ///   from `.task(id:)`, moving the watcher onto the sidebar column, making `columnVisibility` per-window
    ///   `@State` instead of the App's, and — **this one matters, because it is the tidy-up this method invites** —
    ///   moving ALL THREE writes into one `Task { @MainActor }` were each built and launched, and each still
    ///   faulted. Hoisting `scoreID` into the hop below does not simplify this method; it breaks it.
    ///
    /// **The causal model is under-determined, and the measurements are what carry this, not the rule.** "At most one
    /// write in the handler" fits every row, but it does not explain why three writes inside one deferred `Task`
    /// still fault while the same three split one-and-two do not. Do not extend the rule by reasoning — re-measure.
    ///
    /// So exactly one write stays here: the window's score, which is what puts the reader on screen and is the one
    /// that would visibly lag the import if it waited. The other two go together one main-actor hop later, where
    /// nothing is updating and they coalesce. Measured clean, twice, with the score opening and the sidebar
    /// collapsing as before; every arrangement that leaves two writes in this handler faults, including simply
    /// dropping the sidebar collapse.
    ///
    /// The hop is safe for `pendingScoreToOpen` specifically: the only reader is the watcher above, which is keyed on
    /// the id changing, so a value that stays set for one hop cannot re-trigger anything.
    private func openImportedScore(_ item: ScoreItem) {
        scoreID = item.id
        Task { @MainActor in
            libraryVM.pendingScoreToOpen = nil
            columnVisibility = .detailOnly
        }
    }

    private var sidebar: some View {
        LibraryRootScreen(
            viewModel: libraryVM,
            path: $sidebarPath,
            onOpenScore: { item in
                openScore(item)
            },
            readerDestination: { _ in
                // PARITY(macos): library → reader navigation seam — LibraryRootScreen's readerDestination closures
                //   exist for the iOS NavigationStack push. On the Mac the detail column owns the reader, so these
                //   are never entered. If a Mac ever needs an in-sidebar push (a playlist drill-down that opens a
                //   score in place), this is where it hooks in.
                EmptyView()
            },
            playlistReaderDestination: { _ in
                EmptyView()
            },
            onOpenInPlaylist: { item, _ in
                // PARITY(macos): playlist context in the reader — the window carries a score id and nothing else, so
                //   `MacReaderRootScreen` opens the score standalone and the playlist's continuation control and
                //   end-of-score auto-advance are unreachable. Threading a `PlaylistID` through `MacWindowScore` is
                //   what closes it.
                openScore(item)
            },
            licenseContent: { LicenseListView() },
            leadingToolbarItem: { EmptyView() },
        )
        .dropDestination(for: URL.self) { urls, _ in
            let importable = urls.filter(ScoreImportContentTypes.isImportable)
            guard !importable.isEmpty else { return false }
            Task {
                for url in importable {
                    await libraryVM.startImport(from: url)
                }
            }
            return true
        }
    }

    @ViewBuilder
    private var detail: some View {
        if let item = openScoreItem {
            // `id(item.id)` so switching the detail column to another score builds a fresh `MacReaderRootScreen` —
            // and with it a fresh `ReaderViewModel`, which is created once per screen instance in a `@State`.
            MacReaderRootScreen(
                scoreItem: item,
                repository: repository,
                originalStore: originalStore,
                gateway: gateway,
                shareService: shareService,
                metadataReader: metadataReader,
                annotationCoordinator: annotationCoordinator,
                scoresDirectory: AppPaths.scoresDirectory,
                playbackController: bootstrap.playbackController,
                // The same OMR parser the iOS shell passes. It is what gives an imported PDF its on-PDF cursor and
                // click-to-seek; without it the document still reads, it just carries no musical positions.
                pdfPlaybackParser: bootstrap.pdfPlaybackParser,
                analytics: bootstrap.analytics ?? NoopAnalytics(),
            )
            .id(item.id)
        } else {
            // No score chosen yet — or the window's `scoreID` names a row the library no longer holds (deleted in
            // another window, or a restored window value that outlived its score). Both read as an empty detail.
            ContentUnavailableView {
                Label {
                    Text("app.detail.empty.title")
                } icon: {
                    Image(systemName: "music.note")
                }
            }
        }
    }

    /// The `ScoreItem` this window's `scoreID` names, looked up in the library's live rows (`scoreItems` excludes
    /// soft-deleted ones — those are `deletedScoreItems`). Two things only: the reader is built from the current row
    /// rather than a stale copy, and a `scoreID` whose row is gone yields `nil` and an empty detail. It does NOT
    /// push later edits into a reader that is already open — `MacReaderRootScreen` seeds its view model once per
    /// `.id(item.id)`, and a title edit does not change the id.
    private var openScoreItem: ScoreItem? {
        guard let scoreID else { return nil }
        return repository.scoreItems.first { $0.id == scoreID }
    }
}

extension View {
    /// Publishes `id` as this window's focused score, for `MacCommands`'s File ▸ Open in New Tab to read via
    /// `@FocusedValue`. Omitted entirely (rather than published as `nil`) when there is no open score, which is
    /// exactly what leaves `@FocusedValue` reading `nil` and the menu command disabled.
    @ViewBuilder
    fileprivate func focusedCurrentScoreID(_ id: ScoreItem.ID?) -> some View {
        if let id {
            focusedSceneValue(\.macCurrentScoreID, id)
        } else {
            self
        }
    }
}
