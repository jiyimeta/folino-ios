@testable import Reader
import SwiftUI
import Testing

/// What the strip contributes to the score's top inset is the one thing this design exists to keep constant: if it
/// changes when an edit session starts, a paged score re-paginates under the user mid-edit.
///
/// Note what is asserted and what is not. These test the inset the strip CONTRIBUTES, never a total that includes the
/// system's own safe area. An earlier draft of this design asserted the total and would have passed while the real
/// inset moved, because it assumed hiding the status bar shrinks the safe area — which it does not do on any device
/// with a display cutout.
@Suite("Reader top bar layout")
struct ReaderTopBarLayoutTests {
    /// Every top safe-area inset that ships: landscape, an SE, an iPad, and the cutout devices.
    private static let safeAreaInsets: [CGFloat] = [0, 20, 24, 44, 47, 54, 59]

    @Test func `the contributed inset is the control tier and nothing else`() {
        for inset in Self.safeAreaInsets {
            for isEditing in [false, true] {
                #expect(
                    ReaderTopBarLayout.contributedInset(topSafeAreaInset: inset, isEditing: isEditing)
                        == ReaderTopBarLayout.controlTierHeight,
                )
            }
        }
    }

    @Test func `the contributed inset does not move when an edit session starts`() {
        for inset in Self.safeAreaInsets {
            #expect(
                ReaderTopBarLayout.contributedInset(topSafeAreaInset: inset, isEditing: false)
                    == ReaderTopBarLayout.contributedInset(topSafeAreaInset: inset, isEditing: true),
            )
        }
    }

    @Test func `a cutout tier exists only where a control fits in the reserved band`() {
        #expect(ReaderTopBarLayout.hasCutoutTier(topSafeAreaInset: 0) == false)
        #expect(ReaderTopBarLayout.hasCutoutTier(topSafeAreaInset: 20) == false)
        #expect(ReaderTopBarLayout.hasCutoutTier(topSafeAreaInset: 24) == false)
        #expect(ReaderTopBarLayout.hasCutoutTier(topSafeAreaInset: 47))
        #expect(ReaderTopBarLayout.hasCutoutTier(topSafeAreaInset: 59))
    }

    @Test func `the cutout tier boundary is the minimum tappable height`() {
        let boundary = ReaderTopBarLayout.minimumCutoutTierHeight
        #expect(ReaderTopBarLayout.hasCutoutTier(topSafeAreaInset: boundary))
        #expect(ReaderTopBarLayout.hasCutoutTier(topSafeAreaInset: boundary - 0.5) == false)
    }
}
