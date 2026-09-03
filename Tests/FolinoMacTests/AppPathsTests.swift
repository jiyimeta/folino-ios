@testable import folino
import Testing

/// Ⅷ §2: the Mac does not participate in the cross-app App Group. `SharedContainerTasks` already declines all five
/// launch tasks by construction; this is the other half — the SoundFont path, which is shared code and would
/// otherwise resolve into a group container the sandbox has no entitlement for.
struct AppPathsTests {
    @Test func `the shared App Group container is unavailable on macOS`() {
        #expect(AppPaths.sharedContainer == nil)
    }

    @Test func `the shared SoundFont directory is unavailable on macOS`() {
        #expect(AppPaths.sharedSoundfontsDirectory == nil)
    }

    @Test func `soundFonts resolve to the private Application Support directory`() {
        #expect(AppPaths.soundfontsDirectory == AppPaths.legacySoundfontsDirectory)
    }
}
