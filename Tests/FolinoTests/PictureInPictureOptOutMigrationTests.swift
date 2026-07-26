import Domain
@testable import folino
import Foundation
import Testing

struct PictureInPictureOptOutMigrationTests {
    private func makeDefaults() -> UserDefaults {
        let suiteName = "test.pipMigration.\(UUID().uuidString)"
        // swiftlint:disable:next force_unwrapping
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    private let pipKey = ReaderGlobalSettingsKey.pictureInPictureEnabled

    @Test func `force enables a user who had turned it off`() {
        let defaults = makeDefaults()
        defaults.set(false, forKey: pipKey)
        PictureInPictureOptOutMigration.apply(to: defaults)
        #expect(defaults.bool(forKey: pipKey) == true)
        #expect(defaults.bool(forKey: PictureInPictureOptOutMigration.appliedKey) == true)
    }

    @Test func `seeds a fresh install that never touched the toggle`() {
        let defaults = makeDefaults()
        #expect(defaults.object(forKey: pipKey) == nil)
        PictureInPictureOptOutMigration.apply(to: defaults)
        #expect(defaults.bool(forKey: pipKey) == true)
    }

    @Test func `a later opt-out survives a second launch`() {
        let defaults = makeDefaults()
        PictureInPictureOptOutMigration.apply(to: defaults)
        // The user turns PiP off again after the migration ran.
        defaults.set(false, forKey: pipKey)
        PictureInPictureOptOutMigration.apply(to: defaults)
        #expect(defaults.bool(forKey: pipKey) == false)
    }
}
