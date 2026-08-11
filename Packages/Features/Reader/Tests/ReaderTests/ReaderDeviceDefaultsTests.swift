@testable import Reader
import Testing
import UIKit

/// The defaults an untouched per-score preference resolves to. Pinned as a pair because the two values move together:
/// a phone gets the smaller staff AND ignores authored breaks, a tablet gets neither.
@MainActor
struct ReaderDeviceDefaultsTests {
    @Test func `each device class gets its own pair`() {
        #expect(ReaderDeviceDefaults.staffSize(isTablet: false) == 12)
        #expect(ReaderDeviceDefaults.staffSize(isTablet: true) == 14)
        #expect(ReaderDeviceDefaults.honorLayoutBreaks(isTablet: false) == false)
        #expect(ReaderDeviceDefaults.honorLayoutBreaks(isTablet: true) == true)
    }

    /// The live accessors must agree with the pure ones for whatever device the test happens to run on, so a future
    /// edit cannot change one without the other.
    @Test func `the live accessors follow the running device's idiom`() {
        let isTablet = UIDevice.current.userInterfaceIdiom == .pad
        #expect(ReaderDeviceDefaults.staffSize == ReaderDeviceDefaults.staffSize(isTablet: isTablet))
        #expect(ReaderDeviceDefaults.honorLayoutBreaks == ReaderDeviceDefaults.honorLayoutBreaks(isTablet: isTablet))
    }
}
