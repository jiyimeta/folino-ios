import SwiftUI

/// The Mac app's entry point. Task 4 replaces this body with the real `WindowGroup(for:)` scene graph; until then it
/// exists so the target has something to launch, and so the build gate has something to fail on.
@main
struct FolinoMacApp: App {
    var body: some Scene {
        WindowGroup {
            Text(verbatim: "folino")
                .frame(minWidth: 640, minHeight: 480)
        }
    }
}
