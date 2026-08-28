// swiftlint:disable file_length
// AppShellView is the composition root that wires every Feature's root screen, navigation state, and incoming-URL /
// share-drain handling for both compact and regular layouts; its breadth keeps it just over the file_length budget.

import Domain
import ImportExport
import Library
import LicenseList
import Reader
import Settings
import StoreKit
import SwiftUI
import UtilityCore
import UtilityUI

struct AppShellView: View {
    let bootstrap: AppBootstrap
    @Bindable var reviewPrompt: ReviewPromptCoordinator
    @Bindable var versionHistoryPresenter: VersionHistoryPresenter
    @Environment(\.requestReview) private var requestReview
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Group {
            if let repository = bootstrap.repository,
               let importer = bootstrap.importer,
               let gateway = bootstrap.gateway,
               let originalStore = bootstrap.originalStore,
               let shareService = bootstrap.shareService,
               let metadataReader = bootstrap.metadataReader,
               let annotationCoordinator = bootstrap.annotationCoordinator,
               bootstrap.isReady
            {
                ReadyShell(
                    bootstrap: bootstrap,
                    repository: repository,
                    importer: importer,
                    gateway: gateway,
                    originalStore: originalStore,
                    editHistoryStore: bootstrap.editHistoryStore,
                    shareService: shareService,
                    metadataReader: metadataReader,
                    vocalTunerHandoff: LiveVocalTunerHandoff(),
                    annotationCoordinator: annotationCoordinator,
                    scoresDirectory: AppPaths.scoresDirectory,
                    versionHistoryPresenter: versionHistoryPresenter,
                )
            } else if let failure = bootstrap.failure {
                ContentUnavailableView {
                    Label {
                        Text("app.bootstrap.error.title")
                    } icon: {
                        Image(systemName: "exclamationmark.triangle")
                    }
                } description: {
                    Text((failure as? LocalizedError)?.errorDescription ?? failure.localizedDescription)
                }
            } else {
                ProgressView().controlSize(.large)
            }
        }
        .alert(Text("app.review.preprompt.title"), isPresented: $reviewPrompt.isPrePromptPresented) {
            Button { requestReview() } label: { Text("app.review.preprompt.rate") }
            Button(role: .cancel) {} label: { Text("app.review.preprompt.notNow") }
        } message: {
            Text("app.review.preprompt.message")
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active {
                bootstrap.pruneRecentlyDeletedIfNeeded()
                bootstrap.museScoreGeneralProvider?.handleForeground()
            }
        }
        .task(id: bootstrap.isReady) {
            // Kick off MuseScore_General download once bootstrap finishes — Wi-Fi only by default, no-op when opt-out
            // toggle is off or file already present. Safe to call on every isReady transition; the provider gates
            // re-entry internally.
            guard bootstrap.isReady else { return }
            bootstrap.museScoreGeneralProvider?.startDownloadIfNeeded()
        }
        .shareDuplicateAlert(resolver: bootstrap.shareDuplicateResolver)
        .sheet(isPresented: $versionHistoryPresenter.isSheetPresented) {
            if let viewModel = versionHistoryPresenter.sheetViewModel {
                NavigationStack {
                    VersionHistoryScreen(
                        viewModel: viewModel,
                        onAppear: { versionHistoryPresenter.markCurrentVersionAsSeen() },
                    )
                    .navigationTitle(Text(VersionHistoryStrings.title))
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button {
                                versionHistoryPresenter.isSheetPresented = false
                            } label: {
                                L10n.Common.done
                            }
                        }
                    }
                }
            }
        }
    }
}

private struct ReadyShell: View {
    let bootstrap: AppBootstrap
    let repository: any ScoreLibraryRepository
    let importer: any ScoreFileImporter
    let gateway: any ScoreFileGateway
    let originalStore: any ScoreOriginalStore
    let editHistoryStore: any ScoreEditHistoryStore
    let shareService: any ScoreShareService
    let metadataReader: any ScoreMetadataReading
    let vocalTunerHandoff: any VocalTunerHandoff
    let annotationCoordinator: AnnotationSaveCoordinator
    let scoresDirectory: URL
    let versionHistoryPresenter: VersionHistoryPresenter

    @State private var libraryVM: LibraryViewModel
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.scenePhase) private var scenePhase
    /// Layout-deciding size class, committed only while the scene is `.active`. iPadOS transiently reports `.compact`
    /// while the app backgrounds and PiP resizes the scene; branching the top-level layout directly on the live
    /// `horizontalSizeClass` would tear down the `NavigationSplitView` (and the Reader detail's `@State` view model,
    /// and with it the PiP coordinator that AVKit is mid-presenting) on that spurious flip, then rebuild it — leaving a
    /// frozen, uncontrollable PiP window owned by the orphaned old coordinator. Holding the committed value steady
    /// across background-only flips keeps the detail — and the live PiP — intact. Real layout changes (rotation, Stage
    /// Manager / Split View resize) happen while active and are picked up normally.
    @State private var committedSizeClass: UserInterfaceSizeClass?
    @State private var compactPath: NavigationPath
    @State private var sidebarPath: NavigationPath
    @State private var detailScoreItem: ScoreItem?
    @State private var detailPlaylistID: PlaylistID?
    @State private var isSettingsPresented = false
    @State private var columnVisibility: NavigationSplitViewVisibility
    @State private var navStateStore = NavigationStateStore()
    @State private var drainBannerMessage: String?
    /// Driven by whichever Reader is on screen (`onStatusBarHiddenChange`), applied here because this is where it
    /// works: the same modifier inside the Reader's own `navigationDestination` is silently dropped — the window
    /// scene kept reporting the status bar visible while the Reader asked for it to go. See that closure's doc
    /// comment on `ReaderRootScreen`. The Reader hands back `false` on disappear, so a pop can't strand the app
    /// without a clock.
    @State private var readerHidesStatusBar = false
    #if DEBUG
    @State private var isDebugMenuPresented = false
    #endif

    init(
        bootstrap: AppBootstrap,
        repository: any ScoreLibraryRepository,
        importer: any ScoreFileImporter,
        gateway: any ScoreFileGateway,
        originalStore: any ScoreOriginalStore,
        editHistoryStore: any ScoreEditHistoryStore,
        shareService: any ScoreShareService,
        metadataReader: any ScoreMetadataReading,
        vocalTunerHandoff: any VocalTunerHandoff,
        annotationCoordinator: AnnotationSaveCoordinator,
        scoresDirectory: URL,
        versionHistoryPresenter: VersionHistoryPresenter,
    ) {
        self.bootstrap = bootstrap
        self.repository = repository
        self.importer = importer
        self.gateway = gateway
        self.originalStore = originalStore
        self.editHistoryStore = editHistoryStore
        self.shareService = shareService
        self.metadataReader = metadataReader
        self.vocalTunerHandoff = vocalTunerHandoff
        self.annotationCoordinator = annotationCoordinator
        self.scoresDirectory = scoresDirectory
        self.versionHistoryPresenter = versionHistoryPresenter
        _libraryVM = State(
            wrappedValue: LibraryViewModel(
                repository: repository,
                originalStore: originalStore,
                importer: importer,
                gateway: gateway,
                shareService: shareService,
                metadataReader: metadataReader,
                vocalTunerHandoff: vocalTunerHandoff,
                analytics: bootstrap.analytics ?? NoopAnalytics(),
                crashReporter: bootstrap.crashReporter ?? NoopCrashReporter(),
            ),
        )

        let store = NavigationStateStore()
        let restoredCompact = store.loadCompactPath() ?? NavigationPath()
        let restoredSidebar = store.loadSidebarPath() ?? NavigationPath()
        let restoredDetail = store.loadDetailScoreID()
            .flatMap { id in repository.scoreItems.first { $0.id == id } }
        _compactPath = State(wrappedValue: restoredCompact)
        _sidebarPath = State(wrappedValue: restoredSidebar)
        _detailScoreItem = State(wrappedValue: restoredDetail)
        _columnVisibility = State(
            wrappedValue: restoredDetail != nil ? .detailOnly : .doubleColumn,
        )
    }

    private func saveNavSnapshot() {
        navStateStore.save(
            compact: compactPath,
            sidebar: sidebarPath,
            detailScoreID: detailScoreItem?.id,
        )
    }

    /// Pops the compact stack's `NavigationPath` one level — the Reader's `onBack`. Guarded: `removeLast()` traps on
    /// an empty path, and a double-tap on the chevron during the pop transition, before the button itself is torn
    /// down, can reach this twice.
    private func popCompactPath() {
        guard !compactPath.isEmpty else { return }
        compactPath.removeLast()
    }

    /// Snap the user back to library root before an incoming-URL import starts. Called from both the warm-reentry
    /// handler and the cold-launch task so the UI matches the "import in flight" state immediately, rather than waiting
    /// for the import to finish.
    private func resetNavigationForIncomingURL() {
        libraryVM.dismissImportUI()
        isSettingsPresented = false
        versionHistoryPresenter.isSheetPresented = false
        if horizontalSizeClass == .regular {
            sidebarPath = NavigationPath()
            detailPlaylistID = nil
            detailScoreItem = nil
            columnVisibility = .doubleColumn
        } else {
            compactPath = NavigationPath()
        }
    }

    /// The layout folino is committed to — drives both the top-level container choice and navigation routing. Backed by
    /// `committedSizeClass` so a background-only `horizontalSizeClass` flip can't reshuffle the layout out from under
    /// an active PiP session. Falls back to the live environment value before the first commit (initial render).
    private var layoutIsRegular: Bool {
        (committedSizeClass ?? horizontalSizeClass) == .regular
    }

    var body: some View {
        Group {
            if layoutIsRegular {
                NavigationSplitView(columnVisibility: $columnVisibility) {
                    sidebar
                        .navigationSplitViewColumnWidth(min: 350, ideal: 420)
                } detail: {
                    detail
                }
                .navigationSplitViewStyle(.prominentDetail)
            } else {
                LibraryRootScreen(
                    viewModel: libraryVM,
                    path: $compactPath,
                    onOpenScore: { compactPath.append($0) },
                    readerDestination: { item in
                        makeReader(item: item, playlistID: nil, onBack: popCompactPath)
                    },
                    playlistReaderDestination: { route in
                        makeReader(item: route.scoreItem, playlistID: route.playlistID, onBack: popCompactPath)
                    },
                    onOpenInPlaylist: { item, playlistID in
                        compactPath.append(PlaylistReaderRoute(scoreItem: item, playlistID: playlistID))
                    },
                    licenseContent: { LicenseListView() },
                    leadingToolbarItem: { leadingToolbarItems },
                )
            }
        }
        .statusBarHidden(readerHidesStatusBar)
        #if DEBUG
            .debugMenu(isPresented: $isDebugMenuPresented)
        #endif
            .sheet(isPresented: $isSettingsPresented) {
                SettingsSheet(
                    provider: bootstrap.museScoreGeneralProvider,
                    onVersionHistoryViewed: { versionHistoryPresenter.markCurrentVersionAsSeen() },
                    crashReporter: bootstrap.crashReporter ?? NoopCrashReporter(),
                    analytics: bootstrap.analytics ?? NoopAnalytics(),
                ) {
                    LicenseListView()
                }
            }
            .onChange(of: libraryVM.pendingScoreToOpen?.id) { _, newID in
                guard let newID,
                      let item = libraryVM.pendingScoreToOpen,
                      item.id == newID else { return }
                libraryVM.pendingScoreToOpen = nil
                if layoutIsRegular {
                    sidebarPath = NavigationPath()
                    detailPlaylistID = nil
                    detailScoreItem = item
                    columnVisibility = .detailOnly
                } else {
                    compactPath = NavigationPath()
                    compactPath.append(item)
                }
            }
            .task {
                // Cold-launch: drain a URL that .onOpenURL queued before this view appeared.
                if let url = bootstrap.consumePendingIncomingURL() {
                    resetNavigationForIncomingURL()
                    await libraryVM.startImport(from: url)
                }
            }
            .onChange(of: bootstrap.pendingIncomingURL) { _, newValue in
                // Warm re-entry: a URL arrived while the app was already running. Fire-and-forget so the import
                // isn't tied to the view's task lifecycle — `.task(id:)` would cancel its current body when the
                // slot is cleared, surfacing as a persistenceFailed alert.
                guard newValue != nil,
                      let url = bootstrap.consumePendingIncomingURL() else { return }
                resetNavigationForIncomingURL()
                Task { await libraryVM.startImport(from: url) }
            }
            .task {
                // Cold-launch: drain a token queued before the view appeared.
                if let (_, openAfter) = bootstrap.consumePendingShareToken(),
                   let coordinator = bootstrap.incomingShareCoordinator
                {
                    resetNavigationForIncomingURL()
                    await runDrain(coordinator: coordinator, openAfter: openAfter)
                }
            }
            .onChange(of: bootstrap.pendingShareToken) { _, newValue in
                guard newValue != nil,
                      let (_, openAfter) = bootstrap.consumePendingShareToken(),
                      let coordinator = bootstrap.incomingShareCoordinator else { return }
                resetNavigationForIncomingURL()
                Task { await runDrain(coordinator: coordinator, openAfter: openAfter) }
            }
            .task {
                // Cold-launch cross-app hand-off: import whatever a sibling app staged in the shared container — the
                // token `.onOpenURL` queued, plus any leftovers from a hand-off whose URL never landed.
                //
                // Swept here rather than in `AppBootstrap.finishStartup` (where the Share-Extension sweep lives)
                // because `ReadyShell` only exists once bootstrap is ready: an earlier sweep would consume the
                // token before this view could turn it into Reader navigation, and putting the score on screen is
                // the point of one-tap.
                // With no token pending this still runs, so leftovers never pile up — but with `openAfter` false, since
                // a plain launch should not yank the user into a score they asked for days ago.
                guard let coordinator = bootstrap.incomingScoreCoordinator else { return }
                let openAfter = bootstrap.consumePendingOpenScoreToken()?.1 ?? false
                if openAfter {
                    resetNavigationForIncomingURL()
                }
                await runOpenScoreDrain(coordinator: coordinator, openAfter: openAfter)
            }
            .onChange(of: bootstrap.pendingOpenScoreToken) { _, newValue in
                guard newValue != nil,
                      let (_, openAfter) = bootstrap.consumePendingOpenScoreToken(),
                      let coordinator = bootstrap.incomingScoreCoordinator else { return }
                resetNavigationForIncomingURL()
                Task { await runOpenScoreDrain(coordinator: coordinator, openAfter: openAfter) }
            }
            .onChange(of: compactPath) { _, _ in saveNavSnapshot() }
            .onChange(of: sidebarPath) { _, _ in saveNavSnapshot() }
            .onChange(of: detailScoreItem?.id) { _, _ in saveNavSnapshot() }
            .onAppear {
                // Seed the committed layout while active, before any backgrounding can spuriously flip the live value.
                if committedSizeClass == nil {
                    committedSizeClass = horizontalSizeClass
                }
            }
            .onChange(of: horizontalSizeClass) { _, new in
                // Commit only while active: ignore the transient `.compact` iPadOS reports while backgrounding +
                // resizing the scene for PiP, which would otherwise tear down the split view and the live PiP
                // session.
                if scenePhase == .active {
                    committedSizeClass = new
                }
            }
            .onChange(of: scenePhase) { _, phase in
                // Catch up on a real size-class change that landed while away (e.g. Stage Manager resize while
                // backgrounded).
                if phase == .active {
                    committedSizeClass = horizontalSizeClass
                }
            }
            .overlay {
                if libraryVM.isImporting {
                    ImportLoadingHUD()
                }
            }
            .overlay(alignment: .top) {
                if let message = drainBannerMessage {
                    DrainBannerView(message: message)
                        .task {
                            try? await Task.sleep(for: .seconds(2.5))
                            drainBannerMessage = nil
                        }
                }
            }
            .animation(.easeInOut(duration: 0.15), value: libraryVM.isImporting)
            .animation(.easeInOut(duration: 0.2), value: drainBannerMessage)
    }

    @MainActor
    private func runDrain(coordinator: IncomingShareCoordinator, openAfter: Bool) async {
        await applyDrain(coordinator.drain(token: nil), openAfter: openAfter)
    }

    /// Cross-app twin of `runDrain`. Drains every staged token rather than the one named in the URL so a hand-off
    /// whose URL was lost still lands, exactly as the Share-Extension flow does.
    @MainActor
    private func runOpenScoreDrain(coordinator: IncomingScoreCoordinator, openAfter: Bool) async {
        await applyDrain(coordinator.drain(token: nil), openAfter: openAfter)
    }

    @MainActor
    private func applyDrain(_ result: DrainResult, openAfter: Bool) {
        drainBannerMessage = DrainBannerComposer.message(for: result)

        switch ShareDrainNavigation.decide(for: result, openAfter: openAfter) {
        case .none:
            return
        case let .openList(route):
            // Multi-file import: jump to the destination list, not Reader.
            if layoutIsRegular {
                sidebarPath = NavigationPath()
                sidebarPath.append(route)
                detailScoreItem = nil
                columnVisibility = .doubleColumn
            } else {
                compactPath = NavigationPath()
                compactPath.append(route)
            }
        case let .openReader(item, playlistUnderneath):
            // Single import or dedupe-to-existing: push Reader, with the target playlist underneath so the Back
            // affordance lands there.
            if layoutIsRegular {
                sidebarPath = NavigationPath()
                if let playlistUnderneath {
                    sidebarPath.append(playlistUnderneath)
                }
                detailPlaylistID = nil
                detailScoreItem = item
                columnVisibility = .detailOnly
            } else {
                compactPath = NavigationPath()
                if let playlistUnderneath {
                    compactPath.append(playlistUnderneath)
                }
                compactPath.append(item)
            }
        }
    }

    private func makeReader(
        item: ScoreItem,
        playlistID: PlaylistID?,
        onBack: (@MainActor () -> Void)? = nil,
        onToggleSidebar: (@MainActor () -> Void)? = nil,
    ) -> some View {
        EditableReaderScreen(
            item: item,
            scoresDirectory: scoresDirectory,
            gateway: gateway,
            repository: repository,
            originalStore: originalStore,
            historyStore: editHistoryStore,
            playbackController: bootstrap.playbackController,
        ) { host, chrome, topBar, cutoutTier in
            ReaderRootScreen(
                scoreItem: item,
                repository: repository,
                originalStore: originalStore,
                gateway: gateway,
                shareService: shareService,
                vocalTunerHandoff: vocalTunerHandoff,
                metadataReader: metadataReader,
                annotationCoordinator: annotationCoordinator,
                scoresDirectory: scoresDirectory,
                playbackController: bootstrap.playbackController,
                pdfPlaybackParser: bootstrap.pdfPlaybackParser,
                pdfConversion: bootstrap.pdfScoreConversion,
                museScoreGeneralProvider: bootstrap.museScoreGeneralProvider,
                playlistID: playlistID,
                analytics: bootstrap.analytics ?? NoopAnalytics(),
                // Best-effort origin from what this funnel knows: a playlist context vs. the general library.
                // Finer-grained sources (favorites/tag/recents/search) would require threading the source through
                // the navigation values.
                openedFrom: playlistID != nil ? .playlist : .libraryAll,
                onBack: onBack,
                onToggleSidebar: onToggleSidebar,
                onStatusBarHiddenChange: { readerHidesStatusBar = $0 },
                editingHost: host,
                editingChrome: chrome,
                editingTopBar: topBar,
                editingCutoutTier: cutoutTier,
            )
        }
    }

    @ViewBuilder
    private var detail: some View {
        if let item = detailScoreItem {
            // The detail column's navigation bar IS the Reader's own, and that is now hidden — so there is
            // no system sidebar toggle left in it. The Reader draws its own instead and flips `columnVisibility`
            // directly; it shows whenever this closure is supplied, in both directions, so it can also collapse an
            // already-open sidebar.
            //
            // `.id` forces a fresh view identity per score so ReaderRootScreen's @State (viewModel seeded from
            // scoreItem in init) is rebuilt when the user opens a different score from the iPad sidebar.
            makeReader(
                item: item,
                playlistID: detailPlaylistID,
                onToggleSidebar: {
                    columnVisibility = columnVisibility == .detailOnly ? .doubleColumn : .detailOnly
                },
            )
            .id(item.id)
        } else {
            emptyDetail
        }
    }

    private var sidebar: some View {
        LibraryRootScreen(
            viewModel: libraryVM,
            path: $sidebarPath,
            onOpenScore: { item in
                detailPlaylistID = nil
                detailScoreItem = item
                columnVisibility = .detailOnly
            },
            readerDestination: { item in
                makeReader(item: item, playlistID: nil)
            },
            playlistReaderDestination: { route in
                makeReader(item: route.scoreItem, playlistID: route.playlistID)
            },
            onOpenInPlaylist: { item, playlistID in
                detailPlaylistID = playlistID
                detailScoreItem = item
                columnVisibility = .detailOnly
            },
            licenseContent: { LicenseListView() },
            leadingToolbarItem: { leadingToolbarItems },
        )
    }

    /// The library's leading bar slot. Settings in every build; the debug entry point beside it in DEBUG ones.
    ///
    /// Both go through this seam rather than through a `.toolbar` of their own, because `LibraryRootScreen` owns the
    /// `NavigationStack` they belong to — see `DebugMenuButton`.
    @ViewBuilder
    private var leadingToolbarItems: some View {
        #if DEBUG
        HStack(spacing: 8) {
            settingsButton
            DebugMenuButton(isPresented: $isDebugMenuPresented)
        }
        #else
        settingsButton
        #endif
    }

    private var settingsButton: some View {
        Button {
            isSettingsPresented = true
            bootstrap.analytics?.log(.settingsOpened())
        } label: {
            Image(systemName: "gear").accessibilityLabel(Text("app.toolbar.settings.label"))
        }
    }

    private var emptyDetail: some View {
        ContentUnavailableView {
            Label {
                Text("app.detail.empty.title")
            } icon: {
                Image(systemName: "music.note")
            }
        }
    }
}
