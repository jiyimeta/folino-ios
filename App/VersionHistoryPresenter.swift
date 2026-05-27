import Domain
import Foundation
import Observation
import OSLog
import Settings
import SettingsLogic

@MainActor
@Observable
final class VersionHistoryPresenter {
    private enum DefaultsKey {
        static let lastOpenedVersionHistory = "app.global.lastOpenedVersionHistory"
    }

    private static let logger = Logger(
        subsystem: "com.KeyNumber.Folino", category: "VersionHistory",
    )

    private let defaults: UserDefaults
    private let loader: any VersionHistoryLoader
    private var hasRegistered = false

    var isSheetPresented = false
    var sheetViewModel: VersionHistoryViewModel?

    init(
        defaults: UserDefaults = .standard,
        loader: any VersionHistoryLoader = DefaultVersionHistoryLoader(),
    ) {
        self.defaults = defaults
        self.loader = loader
    }

    /// Idempotent per-process. Safe to call from `.task` blocks that may run multiple times across iPad multi-window
    /// scenes.
    func registerColdLaunchIfNeeded() {
        guard !hasRegistered else { return }
        hasRegistered = true
        decideAndPresent()
    }

    func markCurrentVersionAsSeen() {
        defaults.set(AppVersion.current.rawValue, forKey: DefaultsKey.lastOpenedVersionHistory)
    }

    private func decideAndPresent() {
        let stored = defaults.string(forKey: DefaultsKey.lastOpenedVersionHistory)
            .flatMap(AppVersion.init(rawValue:)) ?? .zero
        let current = AppVersion.current

        if stored == .zero {
            // First install (or stored value was unparseable): silent bump, no sheet — we have no history to show this
            // user.
            markCurrentVersionAsSeen()
            return
        }
        if stored >= current { return }

        let entries: [VersionHistoryEntry]
        do {
            entries = try loader.load()
        } catch {
            Self.logger.error("version history failed to load: \(error.localizedDescription)")
            return
        }

        let recent = entries.filter { $0.version > stored }
        guard !recent.isEmpty else {
            markCurrentVersionAsSeen()
            return
        }

        sheetViewModel = VersionHistoryViewModel(
            entries: entries, baseline: stored, isHistorySplit: true,
        )
        isSheetPresented = true
    }
}
