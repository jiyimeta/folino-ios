import Domain
import Foundation

extension AppVersion {
    /// Reads the host bundle's `CFBundleShortVersionString` at first access. App-only because Domain
    /// must not depend on `Bundle.main`. Crashes deliberately if the value is missing or malformed —
    /// a misconfigured Info.plist is a build bug, not a runtime condition to recover from.
    public static let current: AppVersion = {
        let raw = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        guard let v = AppVersion(raw) else {
            fatalError("CFBundleShortVersionString is missing or malformed: \(raw)")
        }
        return v
    }()
}
