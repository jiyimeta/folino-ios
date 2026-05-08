import Domain
import Library
import LicenseList
import Reader
import Settings
import StoreKit
import SwiftUI

struct AppShellView: View {
    let bootstrap: AppBootstrap
    @Bindable var reviewPrompt: ReviewPromptCoordinator
    @Environment(\.requestReview) private var requestReview

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
                    scoresDirectory: AppPaths.scoresDirectory
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
    }
}

private struct ReadyShell: View {
    let bootstrap: AppBootstrap
    let repository: any ScoreLibraryRepository
    let importer: any ScoreFileImporter
    let gateway: any ScoreFileGateway
    let shareService: any ScoreShareService
    let scoresDirectory: URL

    @State private var libraryVM: LibraryViewModel
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var compactPath: NavigationPath
    @State private var sidebarPath: NavigationPath
    @State private var detailScoreItem: ScoreItem?
    @State private var isSettingsPresented = false
    @State private var columnVisibility: NavigationSplitViewVisibility
    @State private var navStateStore = NavigationStateStore()

    init(
        bootstrap: AppBootstrap,
        repository: any ScoreLibraryRepository,
        importer: any ScoreFileImporter,
        gateway: any ScoreFileGateway,
        shareService: any ScoreShareService,
        scoresDirectory: URL
    ) {
        self.bootstrap = bootstrap
        self.repository = repository
        self.importer = importer
        self.gateway = gateway
        self.shareService = shareService
        self.scoresDirectory = scoresDirectory
        _libraryVM = State(
            wrappedValue: LibraryViewModel(
                repository: repository,
                importer: importer,
                gateway: gateway,
                shareService: shareService
            )
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
            wrappedValue: restoredDetail != nil ? .detailOnly : .doubleColumn
        )
    }

    private func saveNavSnapshot() {
        navStateStore.save(
            compact: compactPath,
            sidebar: sidebarPath,
            detailScoreID: detailScoreItem?.id
        )
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
                            reachability: bootstrap.reachability
                        )
                    },
                    licenseContent: { LicenseListView() },
                    leadingToolbarItem: { settingsButton }
                )
                #if DEBUG
                .debuggable()
                #endif
            }
        }
        .sheet(isPresented: $isSettingsPresented) {
            SettingsSheet(
                soundfontResolver: bootstrap.soundfontResolver,
                presetCatalog: bootstrap.presetCatalog
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
                detailScoreItem = item
                columnVisibility = .detailOnly
            } else {
                compactPath.append(item)
            }
        }
        .task {
            // Cold-launch: drain a URL that .onOpenURL queued before this view appeared.
            if let url = bootstrap.consumePendingIncomingURL() {
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
            Task { await libraryVM.startImport(from: url) }
        }
        .onChange(of: compactPath) { _, _ in saveNavSnapshot() }
        .onChange(of: sidebarPath) { _, _ in saveNavSnapshot() }
        .onChange(of: detailScoreItem?.id) { _, _ in saveNavSnapshot() }
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
                onBack: {
                    detailScoreItem = nil
                    columnVisibility = .doubleColumn
                }
            )
        } else {
            emptyDetail
        }
    }

    @ViewBuilder
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
                    scoresDirectory: scoresDirectory
                )
            },
            licenseContent: { LicenseListView() },
            leadingToolbarItem: { settingsButton }
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
