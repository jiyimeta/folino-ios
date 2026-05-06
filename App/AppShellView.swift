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
               bootstrap.isReady
            {
                ReadyShell(
                    bootstrap: bootstrap,
                    repository: repository,
                    importer: importer,
                    gateway: gateway,
                    scoresDirectory: AppPaths.scoresDirectory
                )
            } else if let failure = bootstrap.failure {
                ContentUnavailableView {
                    Label("Folino couldn't start", systemImage: "exclamationmark.triangle")
                } description: {
                    Text((failure as? LocalizedError)?.errorDescription ?? failure.localizedDescription)
                }
            } else {
                ProgressView().controlSize(.large)
            }
        }
        .alert("Enjoying Folino?", isPresented: $reviewPrompt.isPrePromptPresented) {
            Button("Rate Folino") { requestReview() }
            Button("Not Now", role: .cancel) {}
        } message: {
            Text("Would you mind taking a moment to leave a review on the App Store?")
        }
    }
}

private struct ReadyShell: View {
    let bootstrap: AppBootstrap
    let repository: any ScoreLibraryRepository
    let importer: any ScoreFileImporter
    let gateway: any ScoreFileGateway
    let scoresDirectory: URL

    @State private var libraryVM: LibraryViewModel
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var compactPath = NavigationPath()
    @State private var sidebarPath = NavigationPath()
    @State private var detailScoreItem: ScoreItem?
    @State private var isSettingsPresented = false
    @State private var columnVisibility: NavigationSplitViewVisibility = .doubleColumn

    init(
        bootstrap: AppBootstrap,
        repository: any ScoreLibraryRepository,
        importer: any ScoreFileImporter,
        gateway: any ScoreFileGateway,
        scoresDirectory: URL
    ) {
        self.bootstrap = bootstrap
        self.repository = repository
        self.importer = importer
        self.gateway = gateway
        self.scoresDirectory = scoresDirectory
        _libraryVM = State(
            wrappedValue: LibraryViewModel(
                repository: repository, importer: importer, gateway: gateway
            )
        )
    }

    var body: some View {
        Group {
            if horizontalSizeClass == .regular {
                NavigationSplitView(columnVisibility: $columnVisibility) {
                    sidebar
                } detail: {
                    if let item = detailScoreItem {
                        ReaderView(
                            scoreItem: item,
                            repository: repository,
                            gateway: gateway,
                            scoresDirectory: scoresDirectory,
                            playbackController: bootstrap.playbackController,
                            reachability: bootstrap.reachability
                        )
                    } else {
                        ContentUnavailableView(
                            "Select a score",
                            systemImage: "music.note"
                        )
                    }
                }
            } else {
                LibraryRootView(
                    viewModel: libraryVM,
                    path: $compactPath,
                    onOpenScore: { compactPath.append($0) },
                    readerDestination: { item in
                        ReaderView(
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
    }

    @ViewBuilder
    private var sidebar: some View {
        LibraryRootView(
            viewModel: libraryVM,
            path: $sidebarPath,
            onOpenScore: { item in
                detailScoreItem = item
                columnVisibility = .detailOnly
            },
            readerDestination: { item in
                ReaderView(
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
            Image(systemName: "gear").accessibilityLabel("Settings")
        }
    }
}
