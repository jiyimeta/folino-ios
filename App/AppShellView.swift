import Domain
import ImportExport
import Library
import LicenseList
import Reader
import Settings
import StoreKit
import SwiftUI
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
               bootstrap.isReady
            {
                ReadyShell(
                    bootstrap: bootstrap,
                    repository: repository,
                    importer: importer,
                    gateway: gateway,
                    shareService: shareService,
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
    let scoresDirectory: URL
    let versionHistoryPresenter: VersionHistoryPresenter

    @State private var libraryVM: LibraryViewModel
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var compactPath: NavigationPath
    @State private var sidebarPath: NavigationPath
    @State private var detailScoreItem: ScoreItem?
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
        scoresDirectory: URL,
        versionHistoryPresenter: VersionHistoryPresenter,
    ) {
        self.bootstrap = bootstrap
        self.repository = repository
        self.importer = importer
        self.gateway = gateway
        self.shareService = shareService
        self.scoresDirectory = scoresDirectory
        self.versionHistoryPresenter = versionHistoryPresenter
        _libraryVM = State(
            wrappedValue: LibraryViewModel(
                repository: repository,
                importer: importer,
                gateway: gateway,
                shareService: shareService,
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

    /// Snap the user back to library root before an incoming-URL import
    /// starts. Called from both the warm-reentry handler and the cold-launch
    /// task so the UI matches the "import in flight" state immediately,
    /// rather than waiting for the import to finish.
    private func resetNavigationForIncomingURL() {
        libraryVM.dismissImportUI()
        isSettingsPresented = false
        versionHistoryPresenter.isSheetPresented = false
        if horizontalSizeClass == .regular {
            sidebarPath = NavigationPath()
            detailScoreItem = nil
            columnVisibility = .doubleColumn
        } else {
            compactPath = NavigationPath()
        }
    }

    var body: some View {
        Group {
            if horizontalSizeClass == .regular {
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
                        ReaderRootScreen(
                            scoreItem: item,
                            repository: repository,
                            gateway: gateway,
                            scoresDirectory: scoresDirectory,
                            playbackController: bootstrap.playbackController,
                            reachability: bootstrap.reachability,
                        )
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
                soundfontResolver: bootstrap.soundfontResolver,
                presetCatalog: bootstrap.presetCatalog,
                onVersionHistoryViewed: { versionHistoryPresenter.markCurrentVersionAsSeen() },
            ) {
                LicenseListView()
            }
        }
        .onChange(of: libraryVM.pendingScoreToOpen?.id) { _, newID in
            guard let newID,
                  let item = libraryVM.pendingScoreToOpen,
                  item.id == newID else { return }
            libraryVM.pendingScoreToOpen = nil
            if horizontalSizeClass == .regular {
                sidebarPath = NavigationPath()
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
            // Warm re-entry: a URL arrived while the app was already running.
            // Fire-and-forget so the import isn't tied to the view's task
            // lifecycle — `.task(id:)` would cancel its current body when the
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
        .onChange(of: compactPath) { _, _ in saveNavSnapshot() }
        .onChange(of: sidebarPath) { _, _ in saveNavSnapshot() }
        .onChange(of: detailScoreItem?.id) { _, _ in saveNavSnapshot() }
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
        guard openAfter else { return }

        if result.imported.count >= 2 {
            // Multi-file import: jump to the destination list, not Reader.
            let route: LibraryRoute = result.targetPlaylistID
                .map(LibraryRoute.playlistDetail)
                ?? .allScores
            if horizontalSizeClass == .regular {
                sidebarPath = NavigationPath()
                sidebarPath.append(route)
                detailScoreItem = nil
                columnVisibility = .doubleColumn
            } else {
                compactPath = NavigationPath()
                compactPath.append(route)
            }
        } else if let openID = result.openAfter,
                  let item = repository.scoreItems.first(where: { $0.id == openID })
        {
            // Single import or dedupe-to-existing: push Reader, with the
            // target playlist underneath so the Back affordance lands there.
            let playlistRoute: LibraryRoute? = result.targetPlaylistID
                .map(LibraryRoute.playlistDetail)
            if horizontalSizeClass == .regular {
                sidebarPath = NavigationPath()
                if let playlistRoute {
                    sidebarPath.append(playlistRoute)
                }
                detailScoreItem = item
                columnVisibility = .detailOnly
            } else {
                compactPath = NavigationPath()
                if let playlistRoute {
                    compactPath.append(playlistRoute)
                }
                compactPath.append(item)
            }
        }
    }

    @ViewBuilder
    private var detail: some View {
        if let item = detailScoreItem {
            ReaderRootScreen(
                scoreItem: item,
                repository: repository,
                gateway: gateway,
                scoresDirectory: scoresDirectory,
                playbackController: bootstrap.playbackController,
                reachability: bootstrap.reachability,
                onBack: { columnVisibility = .doubleColumn },
                hidesBackButton: columnVisibility == .doubleColumn,
            )
            // Force a fresh view identity per score so ReaderRootScreen's
            // @State (viewModel seeded from scoreItem in init) is rebuilt
            // when the user opens a different score from the iPad sidebar.
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
                detailScoreItem = item
                columnVisibility = .detailOnly
            },
            readerDestination: { item in
                ReaderRootScreen(
                    scoreItem: item,
                    repository: repository,
                    gateway: gateway,
                    scoresDirectory: scoresDirectory,
                )
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
