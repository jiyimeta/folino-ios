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
            libraryVM.pendingScoreToOpen = nil
            openScore(item)
        }
    }

    /// Show `item` in this window and put the sidebar behind it. The one place all three callers — a click in the
    /// library, a playlist open, and the post-import watcher above — express "open this score here".
    ///
    /// **Both writes are guarded on inequality, and that is not only hygiene.** Making both of them inside a single
    /// SwiftUI update pass asks the split view's navigation observer to update twice in one frame, and SwiftUI logs
    /// `Update NavigationRequestObserver tried to update multiple times per frame` at FAULT level. Measured on the
    /// watcher above — the only caller that runs inside an update — one mode per instrumented launch:
    ///
    /// * Either write ALONE from the watcher is clean. The two together are not, and so is either one paired with
    ///   `pendingScoreToOpen = nil` (clearing the value the watcher itself observes re-fires it in the same frame).
    /// * The identical pair made from a settled async context is clean. That is why the two user-driven callers do
    ///   not trigger it: a button action runs outside any update, so SwiftUI coalesces the pair into one update.
    /// * Nothing rearranges out of it. Splitting the two writes across two chained `onChange`s, deferring with
    ///   `Task { @MainActor }` or `DispatchQueue.main.async`, moving the watcher onto the sidebar column, running the
    ///   handoff from `.task(id:)`, and making `columnVisibility` per-window `@State` instead of the App's were each
    ///   built and launched, and each still faulted. SwiftUI runs all of those within the pass the observable change
    ///   started.
    ///
    /// So the guards are the reduction actually available here: every later open in a window whose sidebar is already
    /// collapsed makes one write, not two. Closing the last case is a decision above this seam — either the Mac stops
    /// auto-collapsing the sidebar when a score opens (which is the macOS idiom; ⌘0 still collapses it), or the
    /// post-import handoff waits for the update to settle, at the cost of a visible delay before the score appears.
    private func openScore(_ item: ScoreItem) {
        if scoreID != item.id {
            scoreID = item.id
        }
        if columnVisibility != .detailOnly {
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
                // PARITY(macos): score playback from the Mac reader — `AudioStack.playbackController` is nil until a
                //   later task builds the AVAudioSession-free controller, so the transport has nothing to drive.
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
