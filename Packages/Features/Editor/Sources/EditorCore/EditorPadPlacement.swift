import Foundation

/// Which edge the note-input pad is docked to.
///
/// Modeled on `PKToolPicker`, which the user can drag to another edge when it covers what they're working on. The
/// pencil picker docks to all four edges; this one only moves between top and bottom, because the pad is a
/// full-width row of keys — parking it on a side edge would leave it either unusably narrow or covering half the
/// score. (Going off a side edge is the TUCK, which is dismissal rather than a dock — see
/// `EditorPadTuckGeometry`.)
public enum EditorPadPlacement: String, Sendable, CaseIterable {
    case top
    case bottom

    /// The discriminator the JNI boundary speaks — the same integer-not-a-second-enum rule
    /// `EditorPadTuckSide.rawIndex` follows. 0 = top, 1 = bottom.
    public var rawIndex: Int32 {
        switch self {
        case .top: 0
        case .bottom: 1
        }
    }

    public init(rawIndex: Int32) {
        self = rawIndex == 0 ? .top : .bottom
    }

    /// Where a drag has to end up for the pad to re-dock. A drag is judged by where the pad's own center lands,
    /// not by raw translation, so a short flick from the bottom edge doesn't fly to the top.
    public static func nearest(toCenterY centerY: Double, in height: Double) -> EditorPadPlacement {
        centerY < height / 2 ? .top : .bottom
    }
}
