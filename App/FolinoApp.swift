import SwiftUI

@main
struct FolinoApp: App {
    @State private var bootstrap = AppBootstrap()
    @State private var reviewPrompt = ReviewPromptCoordinator()

    init() {
        EdwinFontLoader.registerOnce()
    }

    var body: some Scene {
        WindowGroup {
            AppShellView(bootstrap: bootstrap, reviewPrompt: reviewPrompt)
                .task {
                    bootstrap.start()
                    reviewPrompt.registerColdLaunchIfNeeded()
                }
                .onOpenURL { bootstrap.acceptIncomingURL($0) }
        }
    }
}
