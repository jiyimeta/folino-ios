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
            Group {
                if let id = ScreenshotEnvironment.requestedSceneID,
                   let scene = ScreenshotScene.allCases.first(where: { $0.id == id })
                {
                    // Explicit scene arg → render just that one. Kept for iterating on a single scene by hand.
                    scene.view
                } else if ScreenshotEnvironment.isActive {
                    // Screenshot mode with no scene arg → the capture test is about to take the window over, so put
                    // nothing in it. Building a Reader here would only be torn down a moment later.
                    Color.black.ignoresSafeArea()
                } else {
                    // Plain launch (icon tap / Xcode Run on a device) → the on-device ink capture tool.
                    CaptureScene()
                }
            }
            .environment(\.screenshotIdiom, ScreenshotEnvironment.idiom)
        }
    }
}
