import SwiftUI

/// Which edge the editing cluster (transport + pad) is docked to.
///
/// Modeled on `PKToolPicker`, which the user can drag to another edge when it covers what they're working on. The
/// pencil picker docks to all four edges; this one only moves between top and bottom, because the pad is a full-width
/// row of keys — parking it on a side edge would leave it either unusably narrow or covering half the score.
enum EditorPadPlacement: String, CaseIterable {
    case top
    case bottom

    var alignment: Alignment {
        switch self {
        case .top: .top
        case .bottom: .bottom
        }
    }

    /// Where a drag has to end up for the cluster to re-dock. A drag is judged by where the cluster's own center
    /// lands, not by raw translation, so a short flick from the bottom edge doesn't fly to the top.
    static func nearest(toCenterY centerY: CGFloat, in height: CGFloat) -> EditorPadPlacement {
        centerY < height / 2 ? .top : .bottom
    }
}
