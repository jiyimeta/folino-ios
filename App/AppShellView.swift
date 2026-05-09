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

    /// Snap the user back to library root before an incoming-URL import
    /// starts. Called from both the warm-reentry handler and the cold-launch
    /// task so the UI matches the "import in flight" state immediately,
    /// rather than waiting for the import to finish.
    private func resetNavigationForIncomingURL() {
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
        .onChange(of: compactPath) { _, _ in saveNavSnapshot() }
        .onChange(of: sidebarPath) { _, _ in saveNavSnapshot() }
        .onChange(of: detailScoreItem?.id) { _, _ in saveNavSnapshot() }
        .overlay {
            if libraryVM.isImporting {
                ImportLoadingHUD()
            }
        }
        .animation(.easeInOut(duration: 0.15), value: libraryVM.isImporting)
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
                hidesBackButton: columnVisibility == .doubleColumn
            )
            // Force a fresh view identity per score so ReaderRootScreen's
            // @State (viewModel seeded from scoreItem in init) is rebuilt
            // when the user opens a different score from the iPad sidebar.
            .id(item.id)
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

private struct ImportLoadingHUD: View {
    var body: some View {
        ZStack {
            // Near-invisible tap-capture layer so the user can't reach the
            // library underneath while the import is running.
            Color.black.opacity(0.001)
                .ignoresSafeArea()
                .accessibilityHidden(true)
            VStack(spacing: 16) {
                ProgressView().controlSize(.large)
                Text("app.import.loading.label")
            }
            .padding(24)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
            .accessibilityElement(children: .combine)
        }
        .transition(.opacity)
    }
}
