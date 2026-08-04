import Foundation
@testable import Reader
import Testing

/// The bar locator turns a navigation bar's rendered views into one frame per control. Everything downstream counts
/// items from an edge, so a cluster too many or too few silently points a coach mark at the wrong button — these lock
/// down the shapes both bar styles actually produce.
@MainActor
@Suite("Reader bar item locator")
struct ReaderBarItemLocatorTests {
    /// The stack iOS 26 draws per item — platter, glass, container, button, glyph — is near-concentric, so it has to
    /// come out as ONE control. Frames taken from an iPhone 17 Pro Max running the Reader.
    @Test
    func `the layers of one glass item collapse into a single frame`() {
        let layers = [
            CGRect(x: 323, y: 66, width: 36, height: 36), // platter
            CGRect(x: 320, y: 63, width: 42, height: 42), // pressed-state animation view
            CGRect(x: 323, y: 66, width: 36, height: 36), // glass
            CGRect(x: 331, y: 74, width: 20, height: 20), // glyph
        ]
        #expect(ReaderBarItemLocator.cluster(layers) == [CGRect(x: 320, y: 63, width: 42, height: 42)])
    }

    /// Trailing items sit side by side with a gap. Measured pitch is 56pt for 36pt items, so neighbours share nothing
    /// — but the assertion that matters is the COUNT, since that is what the ordinals are counted against.
    @Test
    func `neighbouring items stay separate`() {
        let items = (0 ..< 5).map { CGRect(x: 155 + 56 * $0, y: 66, width: 36, height: 36) }
        #expect(ReaderBarItemLocator.cluster(items).count == 5)
    }

    /// iOS 18 nests a ~30pt button inside a 44pt bar-button container: heavy overlap, one control. Two such controls
    /// pushed until they touch must still read as two.
    @Test
    func `a nested button and its container are one control, and touching controls are two`() {
        let first = CGRect(x: 300, y: 55, width: 44, height: 44)
        let firstButton = CGRect(x: 307, y: 62, width: 30, height: 30)
        let second = CGRect(x: 344, y: 55, width: 44, height: 44)
        let clustered = ReaderBarItemLocator.cluster([first, firstButton, second])
        #expect(clustered == [first, second])
    }

    /// A frame that overlaps its neighbour by a hair — rounding, a 1pt shadow inset — is still a separate control.
    @Test
    func `a hairline overlap does not fuse two controls`() {
        let first = CGRect(x: 300, y: 60, width: 36, height: 36)
        let second = CGRect(x: 335, y: 60, width: 36, height: 36)
        #expect(ReaderBarItemLocator.cluster([first, second]).count == 2)
    }

    @Test
    func `no views means no items`() {
        #expect(ReaderBarItemLocator.cluster([]).isEmpty)
    }
}
