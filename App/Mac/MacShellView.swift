import Domain
import Library
import LicenseList
import ScoreFiles
import SwiftUI
import UtilityCore

/// One Mac window: the library in the sidebar, the score in the detail column. Every window comes from the same
/// `WindowGroup`, which is what gives macOS's automatic window tabbing (⌘T, tab drag-out, Merge All Windows) for
/// free — see the design spec §3.3 for why a separate library `Window` would forfeit that.
struct MacShellView: View {
    let bootstrap: AppBootstrap
    @Binding var scoreID: ScoreItem.ID?
    @Binding var columnVisibility: NavigationSplitViewVisibility

    @State private var libraryVM: LibraryViewModel
    @State private var sidebarPath = NavigationPath()

    init(
        bootstrap: AppBootstrap,
        scoreID: Binding<ScoreItem.ID?>,
        columnVisibility: Binding<NavigationSplitViewVisibility>,
    ) {
        self.bootstrap = bootstrap
        _scoreID = scoreID
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
              let metadataReader = bootstrap.metadataReader
        else {
            fatalError("MacShellView built before AppBootstrap finished starting")
        }
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
            // sidebar) jumps straight to the new score, same as iOS. The Reader itself is still Task 8's; today
            // this only swaps the detail placeholder and collapses the sidebar.
            guard let newID,
                  let item = libraryVM.pendingScoreToOpen,
                  item.id == newID else { return }
            libraryVM.pendingScoreToOpen = nil
            scoreID = item.id
            columnVisibility = .detailOnly
        }
    }

    private var sidebar: some View {
        LibraryRootScreen(
            viewModel: libraryVM,
            path: $sidebarPath,
            onOpenScore: { item in
                scoreID = item.id
                columnVisibility = .detailOnly
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
                // The playlist is dropped rather than threaded through: the detail column is still a placeholder
                // (Task 8), so there is nowhere yet for "which playlist underlies this score" to matter.
                scoreID = item.id
                columnVisibility = .detailOnly
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
        if scoreID == nil {
            ContentUnavailableView {
                Label {
                    Text("app.detail.empty.title")
                } icon: {
                    Image(systemName: "music.note")
                }
            }
        } else {
            // Task 8 replaces this with MacReaderRootScreen.
            Text(verbatim: "score")
        }
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
