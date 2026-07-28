import Domain
import ImportExport
import ImportExportAppGroup
import UtilityCore

/// Cross-app score hand-off wiring: the drain behind `folino://open-score`, and the capability stamp sibling apps read
/// to decide whether that one-tap route exists at all. Split out of `AppBootstrap` so that file stays within its
/// length budget; both halves are launch-time concerns owned by the bootstrap.
extension AppBootstrap {
    /// Builds the drain for hand-offs staged in the shared App Group. `nil` when the shared container is unavailable
    /// (entitlement/provisioning gap), in which case the `folino://open-score` route quietly does nothing — the
    /// sibling has no capability stamp to read either, so it never offers one-tap in the first place.
    func makeIncomingScoreCoordinator(importer: any ScoreFileImporter) -> IncomingScoreCoordinator? {
        AppPaths.sharedContainer.map { container in
            IncomingScoreCoordinator(
                importer: importer,
                sharedContainer: container,
                analytics: analytics ?? NoopAnalytics(),
                crashReporter: crashReporter ?? NoopCrashReporter(),
            )
        }
    }

    /// Publishes `folino/capabilities.json` in the shared App Group so sibling apps can tell that this build accepts
    /// the one-tap hand-off; a sibling that finds no stamp falls back to a share sheet. Written on every launch so the
    /// advertised app and protocol versions follow whatever build is installed. Best-effort: a missing container, or a
    /// write that fails, only costs the sibling its one-tap path.
    func stampSharedCapabilities() {
        guard let container = AppPaths.sharedContainer else { return }
        try? CapabilityStampWriter(sharedContainer: container)
            .stamp(appVersion: AppVersion.current.description)
    }
}
