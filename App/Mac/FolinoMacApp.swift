import Domain
import Foundation
import LicenseList
import Settings
import SwiftUI
import UtilityCore

/// The value that identifies one of `FolinoMacApp`'s windows, and what `WindowGroup(for:)` dedupes on. `scoreID`
/// alone isn't enough: `WindowGroup(for:)` reuses (refocuses) an existing window that already presents an equal
/// value rather than opening a second one, so `openWindow(value:)` with a bare `ScoreItem.ID` would make
/// `MacCommands`'s "Open in New Tab" a no-op whenever the score is already showing in the frontmost window.
/// `tabInstance` exists purely to make every fresh "Open in New Tab" invocation compare unequal to every window
/// already open, guaranteeing a new window every time — it plays no other role and is never read back.
struct MacWindowScore: Hashable, Codable {
    var scoreID: ScoreItem.ID
    var tabInstance = UUID()
}

/// The Mac app's entry point. Drives the real `AppBootstrap` and reports its state — a spinner while it runs, then
/// the window model or the failure. One `WindowGroup(for:)` scene supplies every reading window (and macOS's
/// automatic tabbing along with it — see `MacShellView`); `Settings` is its own scene, as it must be.
@main
struct FolinoMacApp: App {
    @State private var bootstrap = AppBootstrap()
    @State private var columnVisibility: NavigationSplitViewVisibility = .doubleColumn
    /// Owns the "mark this version's history as seen" bookkeeping for `SettingsSheet`'s About section, mirroring
    /// `App/iOS/AppShellView.swift`'s `versionHistoryPresenter`. The cold-launch "show what's new" sheet iOS also
    /// drives from this type is a separate, larger feature (its own presentation host wired into the window
    /// lifecycle) that nothing here has asked for yet — this only supplies the one method Settings needs.
    @State private var versionHistoryPresenter = VersionHistoryPresenter()

    init() {
        EdwinFontLoader.registerOnce()
    }

    var body: some Scene {
        WindowGroup(for: MacWindowScore.self) { $window in
            Group {
                if bootstrap.isReady {
                    MacShellView(bootstrap: bootstrap, window: $window, columnVisibility: $columnVisibility)
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
                onVersionHistoryViewed: { versionHistoryPresenter.markCurrentVersionAsSeen() },
                crashReporter: bootstrap.crashReporter ?? NoopCrashReporter(),
                analytics: bootstrap.analytics ?? NoopAnalytics(),
            ) {
                LicenseListView()
            }
            .frame(minWidth: 480, idealWidth: 560, minHeight: 420, idealHeight: 560)
        }
    }
}
