import Soundfonts

/// `SharedSoundfontReclaimer.installedChecker` on macOS: there is no `UIApplication.canOpenURL` sibling-app probe, and
/// no Mac sibling app to detect yet — always report nothing installed. The reclaimer then falls back to whatever this
/// app's own opt-in state says, exactly as it would on iOS with no siblings installed.
///
/// Mac half of the one-line seam in `App/Shared/AudioStackFactory.platformInstalledChecker`; the iOS half is
/// `App/iOS/UIKitInstalledAppChecker.swift`.
struct NoSiblingAppChecker: InstalledAppChecking {
    func isInstalled(urlScheme: String) -> Bool {
        false
    }
}
