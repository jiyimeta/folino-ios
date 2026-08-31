#if os(iOS)
import UIKit
#endif

/// What an untouched (`nil`) per-score Reader preference resolves to on this device.
///
/// Deliberately keyed on the device *idiom*, not on the live window width. These values are what `nil` resolves to, so
/// a width-driven rule would re-engrave every untouched score the moment the user rotated the device or resized a
/// Split View. The cost is that a genuinely narrow window on an iPad (Slide Over, a 1/3 Split View) still gets the
/// iPad pair — accepted: a default that is occasionally too generous beats one that moves under the reader's hands.
///
/// The two values move together on purpose. A phone viewport is narrower than the page the score was engraved for, so
/// honoring the authored `<LayoutBreak>` boundaries leaves the staves cramped against an empty right margin; wrapping
/// to the viewport at a smaller staff size is what makes the same score readable.
@MainActor
enum ReaderDeviceDefaults {
    /// Engraved staff size for a score the user has never sized themselves.
    static func staffSize(isTablet: Bool) -> Double {
        isTablet ? 14 : 12
    }

    /// Whether a score the user has never configured reproduces the engraver's authored system / page boundaries.
    static func honorLayoutBreaks(isTablet: Bool) -> Bool {
        isTablet
    }

    // The two properties below read the idiom from `UIDevice`, so they exist on iOS only. macOS has no idiom to ask:
    // `MacReaderRootScreen` calls the two portable functions above directly with `isTablet: true`, because a Mac
    // window is a large screen and wants the same generous pair an iPad gets.
    #if os(iOS)
    private static var isTablet: Bool {
        UIDevice.current.userInterfaceIdiom == .pad
    }

    static var staffSize: Double {
        staffSize(isTablet: isTablet)
    }

    static var honorLayoutBreaks: Bool {
        honorLayoutBreaks(isTablet: isTablet)
    }
    #endif
}
