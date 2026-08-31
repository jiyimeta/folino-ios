import Soundfonts
import UIKit

/// Live `InstalledAppChecking` backed by `UIApplication.canOpenURL`. Requires the queried scheme to be listed in
/// `LSApplicationQueriesSchemes` (see `App/Info.plist`).
struct UIKitInstalledAppChecker: InstalledAppChecking {
    func isInstalled(urlScheme: String) -> Bool {
        guard let url = URL(string: "\(urlScheme)://") else { return false }
        return UIApplication.shared.canOpenURL(url)
    }
}
