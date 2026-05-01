import SwiftUI

@main
struct FolinoApp: App {
    @State private var bootstrap = AppBootstrap()

    var body: some Scene {
        WindowGroup {
            AppShellView(bootstrap: bootstrap)
                .task { bootstrap.start() }
        }
    }
}
