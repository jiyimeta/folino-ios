@testable import folino
import Foundation
import Testing

@MainActor
struct ReviewPromptCoordinatorTests {
    private func makeDefaults() -> UserDefaults {
        let suiteName = "test.review.\(UUID().uuidString)"
        // swiftlint:disable:next force_unwrapping
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    @Test func `suppress display still increments counter`() {
        let defaults = makeDefaults()
        defaults.set(9, forKey: "ReviewPrompt.coldLaunchCount")
        let coordinator = ReviewPromptCoordinator(defaults: defaults)
        coordinator.registerColdLaunchIfNeeded(suppressDisplay: true)
        #expect(defaults.integer(forKey: "ReviewPrompt.coldLaunchCount") == 10)
        #expect(coordinator.isPrePromptPresented == false)
    }

    @Test func `suppress display false presents at threshold`() {
        let defaults = makeDefaults()
        defaults.set(9, forKey: "ReviewPrompt.coldLaunchCount")
        let coordinator = ReviewPromptCoordinator(defaults: defaults)
        coordinator.registerColdLaunchIfNeeded(suppressDisplay: false)
        #expect(defaults.integer(forKey: "ReviewPrompt.coldLaunchCount") == 10)
        #expect(coordinator.isPrePromptPresented == true)
    }

    @Test func `default arg matches existing call sites`() {
        let defaults = makeDefaults()
        defaults.set(9, forKey: "ReviewPrompt.coldLaunchCount")
        let coordinator = ReviewPromptCoordinator(defaults: defaults)
        coordinator.registerColdLaunchIfNeeded()
        #expect(coordinator.isPrePromptPresented == true)
    }

    @Test func `idempotent across multiple calls`() {
        let defaults = makeDefaults()
        defaults.set(9, forKey: "ReviewPrompt.coldLaunchCount")
        let coordinator = ReviewPromptCoordinator(defaults: defaults)
        coordinator.registerColdLaunchIfNeeded(suppressDisplay: true)
        coordinator.registerColdLaunchIfNeeded(suppressDisplay: false)
        // Second call is a no-op because hasRegistered is true.
        #expect(defaults.integer(forKey: "ReviewPrompt.coldLaunchCount") == 10)
        #expect(coordinator.isPrePromptPresented == false)
    }
}
