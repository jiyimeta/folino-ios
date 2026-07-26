@testable import Domain
import Testing

@Suite("ReviewPromptCadence")
struct ReviewPromptCadenceTests {
    @Test
    func `no prompt before the first threshold`() {
        for count in 1 ..< ReviewPromptCadence.firstThreshold {
            #expect(!ReviewPromptCadence.shouldPrompt(coldLaunchCount: count))
        }
    }

    @Test
    func `first prompt lands exactly on the threshold launch`() {
        #expect(ReviewPromptCadence.shouldPrompt(coldLaunchCount: ReviewPromptCadence.firstThreshold))
    }

    @Test
    func `then one prompt per interval, and nothing in between`() {
        let first = ReviewPromptCadence.firstThreshold
        let interval = ReviewPromptCadence.interval
        for step in 1 ... 3 {
            let promptingLaunch = first + interval * step
            #expect(ReviewPromptCadence.shouldPrompt(coldLaunchCount: promptingLaunch))
            #expect(!ReviewPromptCadence.shouldPrompt(coldLaunchCount: promptingLaunch - 1))
            #expect(!ReviewPromptCadence.shouldPrompt(coldLaunchCount: promptingLaunch + 1))
        }
    }

    /// A count of 0 is what a fresh install reads before its first increment; it must not prompt, and — since the
    /// arithmetic involves a modulo on a difference — must not trap on the negative either.
    @Test
    func `a zero or negative count never prompts`() {
        #expect(!ReviewPromptCadence.shouldPrompt(coldLaunchCount: 0))
        #expect(!ReviewPromptCadence.shouldPrompt(coldLaunchCount: -1))
    }
}
