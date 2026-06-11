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
               let shareService = bootstrap.shareService,
               let metadataReader = bootstrap.metadataReader,
               bootstrap.isReady
            {
                ReadyShell(
                    bootstrap: bootstrap,
                    repository: repository,
                    importer: importer,
                    gateway: gateway,
                    shareService: shareService,
                    metadataReader: metadataReader,
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
            }
        }
        .task(id: bootstrap.isReady) {
            // Kick off MuseScore_General download once bootstrap finishes — Wi-Fi only by default, no-op when opt-out
            // toggle is off or file already present. Safe to call on every isReady transition; the provider gates
            // re-entry internally.
            guard bootstrap.isReady else { return }
            await bootstrap.museScoreGeneralProvider?.startDownloadIfNeeded()
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
    let shareService: any ScoreShareService
    let metadataReader: any ScoreMetadataReading
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

    init(
        bootstrap: AppBootstrap,
        repository: any ScoreLibraryRepository,
        importer: any ScoreFileImporter,
        gateway: any ScoreFileGateway,
        shareService: any ScoreShareService,
        metadataReader: any ScoreMetadataReading,
        scoresDirectory: URL,
        versionHistoryPresenter: VersionHistoryPresenter,
    ) {
        self.bootstrap = bootstrap
        self.repository = repository
        self.importer = importer
        self.gateway = gateway
        self.shareService = shareService
        self.metadataReader = metadataReader
        self.scoresDirectory = scoresDirectory
        self.versionHistoryPresenter = versionHistoryPresenter
        _libraryVM = State(
            wrappedValue: LibraryViewModel(
                repository: repository,
                importer: importer,
                gateway: gateway,
                shareService: shareService,
                metadataReader: metadataReader,
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
                    #if DEBUG
                        .debuggable()
                    #endif
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
                        makeReader(item: item, playlistID: nil)
                    },
                    playlistReaderDestination: { route in
                        makeReader(item: route.scoreItem, playlistID: route.playlistID)
                    },
                    onOpenInPlaylist: { item, playlistID in
                        compactPath.append(PlaylistReaderRoute(scoreItem: item, playlistID: playlistID))
                    },
                    licenseContent: { LicenseListView() },
                    leadingToolbarItem: { settingsButton },
                )
                #if DEBUG
                .debuggable()
                #endif
            }
        }
        .sheet(isPresented: $isSettingsPresented) {
            SettingsSheet(
                provider: bootstrap.museScoreGeneralProvider,
                onVersionHistoryViewed: { versionHistoryPresenter.markCurrentVersionAsSeen() },
                crashReporter: bootstrap.crashReporter ?? NoopCrashReporter(),
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
            // Warm re-entry: a URL arrived while the app was already running. Fire-and-forget so the import isn't tied
            // to the view's task lifecycle — `.task(id:)` would cancel its current body when the slot is cleared,
            // surfacing as a persistenceFailed alert.
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
        .onChange(of: compactPath) { _, _ in saveNavSnapshot() }
        .onChange(of: sidebarPath) { _, _ in saveNavSnapshot() }
        .onChange(of: detailScoreItem?.id) { _, _ in saveNavSnapshot() }
        .onAppear {
            // Seed the committed layout while active, before any backgrounding can spuriously flip the live value.
            if committedSizeClass == nil { committedSizeClass = horizontalSizeClass }
        }
        .onChange(of: horizontalSizeClass) { _, new in
            // Commit only while active: ignore the transient `.compact` iPadOS reports while backgrounding + resizing
            // the scene for PiP, which would otherwise tear down the split view and the live PiP session.
            if scenePhase == .active { committedSizeClass = new }
        }
        .onChange(of: scenePhase) { _, phase in
            // Catch up on a real size-class change that landed while away (e.g. Stage Manager resize while
            // backgrounded).
            if phase == .active { committedSizeClass = horizontalSizeClass }
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
        let result = await coordinator.drain(token: nil)
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
        onBack: (() -> Void)? = nil,
        hidesBackButton: Bool = false,
    ) -> some View {
        ReaderRootScreen(
            scoreItem: item,
            repository: repository,
            gateway: gateway,
            shareService: shareService,
            metadataReader: metadataReader,
            scoresDirectory: scoresDirectory,
            playbackController: bootstrap.playbackController,
            museScoreGeneralProvider: bootstrap.museScoreGeneralProvider,
            playlistID: playlistID,
            onBack: onBack,
            hidesBackButton: hidesBackButton,
        )
    }

    @ViewBuilder
    private var detail: some View {
        if let item = detailScoreItem {
            makeReader(
                item: item,
                playlistID: detailPlaylistID,
                onBack: { columnVisibility = .doubleColumn },
                hidesBackButton: columnVisibility == .doubleColumn,
            )
            // Force a fresh view identity per score so ReaderRootScreen's @State (viewModel seeded from scoreItem in
            // init) is rebuilt when the user opens a different score from the iPad sidebar.
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
            leadingToolbarItem: { settingsButton },
        )
    }

    private var settingsButton: some View {
        Button {
            isSettingsPresented = true
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
