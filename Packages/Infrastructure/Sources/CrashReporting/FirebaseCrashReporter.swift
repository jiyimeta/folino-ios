import FirebaseCore
import FirebaseCrashlytics
import Foundation
import UtilityCore

/// `CrashReporter` backed by Firebase Crashlytics. The only place in folino that imports the Firebase SDK besides the
/// composition root that calls `configure`.
public struct FirebaseCrashReporter: CrashReporter {
    public init() {}

    /// Configures `FirebaseApp` exactly once and applies the stored collection preference. Call from the composition
    /// root early in launch.
    ///
    /// `FirebaseApp.configure()` reads `GoogleService-Info.plist` from the app bundle and must run on the main thread.
    @MainActor
    public static func configure(collectionEnabled: Bool) -> FirebaseCrashReporter {
        FirebaseApp.configure()
        let reporter = FirebaseCrashReporter()
        reporter.setCollectionEnabled(collectionEnabled)
        return reporter
    }

    public func setCollectionEnabled(_ enabled: Bool) {
        Crashlytics.crashlytics().setCrashlyticsCollectionEnabled(enabled)
    }

    public func log(_ message: String) {
        Crashlytics.crashlytics().log(message)
    }

    public func record(error: Error) {
        Crashlytics.crashlytics().record(error: error)
    }
}
