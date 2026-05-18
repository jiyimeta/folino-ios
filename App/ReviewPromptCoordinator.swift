import Foundation
import Observation

/// Tracks cold launches and decides when to surface the App Store review pre-prompt.
///
/// Cadence: first prompt on the 10th cold launch, then every 40 cold launches after that (50, 90, 130, …). Apple
/// rate-limits `requestReview` to 3 prompts per 365 days regardless of how often we ask, so spacing them out avoids
/// wasting that budget on users who haven't engaged yet.
@MainActor
@Observable
final class ReviewPromptCoordinator {
    private let firstThreshold = 10
    private let interval = 40
    private static let coldLaunchCountKey = "ReviewPrompt.coldLaunchCount"

    private let defaults: UserDefaults
    private var hasRegistered = false

    var isPrePromptPresented = false

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Idempotent per-process. Safe to call from `.task` blocks that may run multiple times across iPad multi-window
    /// scenes.
    ///
    /// Pass `suppressDisplay: true` when another cold-launch sheet (e.g. version history) is taking priority for this
    /// launch. The counter still increments so the cadence keeps moving; the user just doesn't see the pre-prompt this
    /// time around.
    func registerColdLaunchIfNeeded(suppressDisplay: Bool = false) {
        guard !hasRegistered else { return }
        hasRegistered = true

        let count = defaults.integer(forKey: Self.coldLaunchCountKey) + 1
        defaults.set(count, forKey: Self.coldLaunchCountKey)
        if !suppressDisplay, shouldPrompt(at: count) {
            isPrePromptPresented = true
        }
    }

    private func shouldPrompt(at count: Int) -> Bool {
        guard count >= firstThreshold else { return false }
        return (count - firstThreshold) % interval == 0
    }
}
