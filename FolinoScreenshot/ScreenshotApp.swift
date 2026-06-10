import ScreenshotKit
import SwiftUI

@main
struct ScreenshotApp: App {
    init() {
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
