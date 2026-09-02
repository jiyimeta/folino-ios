import Domain
import Foundation
import Observation

/// Tracks cold launches and decides when to surface the App Store review pre-prompt.
///
/// The cadence itself lives in `Domain.ReviewPromptCadence` so Android prompts on the same launches; this type owns
/// only the iOS-side counting and the pre-prompt presentation.
@MainActor
@Observable
final class ReviewPromptCoordinator {
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
        if !suppressDisplay, ReviewPromptCadence.shouldPrompt(coldLaunchCount: count) {
            isPrePromptPresented = true
        }
    }
}
