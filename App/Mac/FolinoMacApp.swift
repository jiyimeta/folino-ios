import SwiftUI

/// The Mac app's entry point. Drives the real `AppBootstrap` and reports its state — a spinner while it runs, then
/// `ready` or the failure. Task 4 replaces this body with the real `WindowGroup(for:)` scene graph.
@main
struct FolinoMacApp: App {
    @State private var bootstrap = AppBootstrap()

    init() {
        EdwinFontLoader.registerOnce()
    }

    var body: some Scene {
        WindowGroup {
            Group {
                if bootstrap.isReady {
                    Text(verbatim: "ready")
                } else if let failure = bootstrap.failure {
                    Text(verbatim: "\(failure)")
                } else {
                    ProgressView()
                }
            }
            .frame(minWidth: 640, minHeight: 480)
            .task { bootstrap.start() }
        }
    }
}
