import Domain
import ImportExportAppGroup
import StoreKit
import UIKit

/// Live `VocalTunerHandoff`. The mirror image of VocalTuner's `LiveFolinoPromotionClient`, and the only type in
/// folino that touches `canOpenURL`, `UIApplication.open`, and StoreKit for this feature — everything below the
/// App layer sees the Domain protocol.
@MainActor
struct LiveVocalTunerHandoff: VocalTunerHandoff {
    /// VocalTuner's App Store id. Hardcoded for the same reason VocalTuner hardcodes folino's: it is a stable
    /// identity, and looking it up at runtime would put a network call in front of a menu tap.
    private static let appStoreID = 1_505_735_245
    private static let urlScheme = "vocaltuner"
    /// App Analytics campaign attribution for taps that originate in folino's share menu.
    private static let campaignToken = "folino-share-menu"
    /// ASC provider token (`pt`) for the shared App Store Connect account.
    private static let ascProviderToken = "121279510"

    /// `SKStoreProductViewControllerDelegate` is held weakly, so one retained instance backs every presentation.
    private static let storeDelegate = VocalTunerStoreDelegate()

    // swiftlint:disable:next force_unwrapping
    private static let probeURL = URL(string: "\(urlScheme)://")!

    var availability: VocalTunerAvailability {
        VocalTunerAvailability.resolve(
            canOpenVocalTuner: UIApplication.shared.canOpenURL(Self.probeURL),
            capabilities: Self.capabilities(),
        )
    }

    func openScore(fileURL: URL, displayName: String) -> VocalTunerHandoffResult {
        guard availability == .installedHandoffCapable,
              let container = SharedScorePaths.container()
        else {
            return .needsShareFallback
        }
        let token = UUID().uuidString
        do {
            try OutgoingScoreStager().stage(
                fileURL: fileURL, displayName: displayName, format: "musescore",
                token: token, into: container, now: Date(),
            )
        } catch {
            // The caller already has the exported file, so the share sheet still gets the score across.
            return .needsShareFallback
        }
        guard let url = URL(string: "\(Self.urlScheme)://open-score?token=\(token)") else {
            return .needsShareFallback
        }
        UIApplication.shared.open(url)
        return .openedViaDeepLink
    }

    func presentAppStore() {
        let controller = SKStoreProductViewController()
        controller.delegate = Self.storeDelegate
        controller.loadProduct(withParameters: [
            SKStoreProductParameterITunesItemIdentifier: Self.appStoreID,
            SKStoreProductParameterCampaignToken: Self.campaignToken,
            SKStoreProductParameterProviderToken: Self.ascProviderToken,
        ])
        Self.topViewController()?.present(controller, animated: true)
    }

    private static func capabilities() -> VocalTunerCapabilities? {
        guard let container = SharedScorePaths.container() else { return nil }
        return VocalTunerCapabilityReader(sharedContainer: container).read()
    }

    private static func topViewController() -> UIViewController? {
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
        var top = scene?.keyWindow?.rootViewController
        while let presented = top?.presentedViewController {
            top = presented
        }
        return top
    }
}

/// Dismisses `SKStoreProductViewController` on "Done". Apple documents dismissal as the delegate's job; relying on
/// the controller dismissing itself is undocumented and would strand the user if that behavior ever changed.
private final class VocalTunerStoreDelegate: NSObject, SKStoreProductViewControllerDelegate {
    func productViewControllerDidFinish(_ viewController: SKStoreProductViewController) {
        viewController.presentingViewController?.dismiss(animated: true)
    }
}
