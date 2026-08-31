import Domain
import LicenseList
import Settings
import SwiftUI
import UtilityCore

/// The Mac app's entry point. Drives the real `AppBootstrap` and reports its state — a spinner while it runs, then
/// the window model or the failure. One `WindowGroup(for:)` scene supplies every reading window (and macOS's
/// automatic tabbing along with it — see `MacShellView`); `Settings` is its own scene, as it must be.
@main
struct FolinoMacApp: App {
    @State private var bootstrap = AppBootstrap()
    @State private var columnVisibility: NavigationSplitViewVisibility = .doubleColumn

    init() {
        EdwinFontLoader.registerOnce()
    }

    var body: some Scene {
        WindowGroup(for: ScoreItem.ID.self) { $scoreID in
            Group {
                if bootstrap.isReady {
                    MacShellView(bootstrap: bootstrap, scoreID: $scoreID, columnVisibility: $columnVisibility)
                } else if let failure = bootstrap.failure {
                    ContentUnavailableView {
                        Text("app.bootstrap.error.title")
                    } description: {
                        Text((failure as? LocalizedError)?.errorDescription ?? failure.localizedDescription)
                    }
                } else {
                    ProgressView()
                }
            }
            .task { bootstrap.start() }
        }
        .commands { MacCommands(columnVisibility: $columnVisibility) }

        Settings {
            SettingsSheet(
                provider: bootstrap.museScoreGeneralProvider,
                onVersionHistoryViewed: {},
                crashReporter: bootstrap.crashReporter ?? NoopCrashReporter(),
                analytics: bootstrap.analytics ?? NoopAnalytics(),
            ) {
                LicenseListView()
            }
            .frame(minWidth: 480, idealWidth: 560, minHeight: 420, idealHeight: 560)
        }
    }
}
