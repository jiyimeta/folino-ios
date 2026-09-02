import Domain
import Foundation

/// One-shot flip of the Reader's Picture-in-Picture setting from opt-in to opt-out.
///
/// PiP shipped defaulting to off, and only ~5% of active users ever turned it on — while of the handful who did,
/// essentially nobody turned it back off. The setting is therefore inverted: the `@AppStorage` default becomes `true`,
/// and this pass force-enables it once for every install that already has a stored value. That deliberately includes
/// the few users who had switched it off; the flag below then makes their next choice stick forever, so a user who
/// turns it off after the migration is never overridden again.
///
/// Android mirrors this in `SettingsPrefs.applyPictureInPictureOptOutMigration()` — same rule, same one-shot flag,
/// expressed against DataStore instead of `UserDefaults`.
enum PictureInPictureOptOutMigration {
    /// `true` once the force-on pass has run. Versioned so a future deliberate re-run can bump to `.v2` instead of
    /// resurrecting this one.
    static let appliedKey = "reader.pictureInPictureForcedOn.v1"

    /// Writes `true` to the PiP key exactly once per install. Cheap enough (two `UserDefaults` reads on the already
    /// warm standard suite) to run unconditionally at bootstrap.
    static func apply(to defaults: UserDefaults) {
        guard !defaults.bool(forKey: appliedKey) else { return }
        defaults.set(true, forKey: ReaderGlobalSettingsKey.pictureInPictureEnabled)
        defaults.set(true, forKey: appliedKey)
    }
}
