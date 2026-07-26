import Foundation

/// Decides, from a cold-launch count, whether this launch is one where the store's review prompt should be surfaced.
///
/// Shared so both platforms ask on the *same* launches. The store APIs underneath differ — Apple rate-limits
/// `requestReview` to 3 prompts per 365 days, Play quietly no-ops a flow it doesn't want to show — but in both cases
/// the budget is finite and out of our hands, so spending it on users who haven't engaged yet is the thing to avoid.
/// Hence: nothing for the first several launches, then a wide interval.
public enum ReviewPromptCadence {
    /// Cold launches before the first prompt.
    public static let firstThreshold = 10

    /// Cold launches between prompts after the first (10, 50, 90, 130, …).
    public static let interval = 40

    /// Whether the launch numbered `coldLaunchCount` (1-based) is a prompting launch.
    ///
    /// Counts below the threshold never prompt; at or above it, only exact multiples of the interval past the
    /// threshold do.
    public static func shouldPrompt(coldLaunchCount: Int) -> Bool {
        guard coldLaunchCount >= firstThreshold else { return false }
        return (coldLaunchCount - firstThreshold) % interval == 0
    }
}
