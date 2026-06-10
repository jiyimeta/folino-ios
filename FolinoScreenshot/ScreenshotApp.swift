import ScreenshotKit
import SwiftUI

@main
struct ScreenshotApp: App {
    init() {
        // Shared idempotent setup (font-metrics provider + onboarding-hint suppression).
        // Also run from each scene's init so SwiftUI previews render real notation.
        ScreenshotSetup.ensure()
        ScreenshotEnvironment.bootstrap()
    }

    var body: some Scene {
        WindowGroup {
            if let id = ScreenshotEnvironment.requestedSceneID,
               let scene = ScreenshotScene.allCases.first(where: { $0.id == id })
            {
                scene.view
                    .environment(\.screenshotIdiom, ScreenshotEnvironment.idiom)
            } else {
                Text("No scene requested")
            }
        }
    }
}
