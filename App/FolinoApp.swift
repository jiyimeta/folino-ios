import SwiftUI

@main
struct FolinoApp: App {
    @State private var bootstrap = AppBootstrap()
    @State private var reviewPrompt = ReviewPromptCoordinator()
    @State private var versionHistoryPresenter = VersionHistoryPresenter()

    init() {
        EdwinFontLoader.registerOnce()
    }

    var body: some Scene {
        WindowGroup {
            AppShellView(
                bootstrap: bootstrap,
                reviewPrompt: reviewPrompt,
                versionHistoryPresenter: versionHistoryPresenter,
            )
            .task {
                bootstrap.start()
                versionHistoryPresenter.registerColdLaunchIfNeeded()
                reviewPrompt.registerColdLaunchIfNeeded(
                    suppressDisplay: versionHistoryPresenter.isSheetPresented,
                )
            }
            .onOpenURL { bootstrap.acceptIncomingURL($0) }
        }
    }
}
