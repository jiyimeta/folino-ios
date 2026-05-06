import CoreGraphics
import SheetMusicCore
import SheetMusicLayout
import SheetMusicUI
import SwiftUI

extension ScoreCursor {
    /// Measure index this cursor is parked on, regardless of `.item`
    /// vs `.beat` flavour. Used by auto-scroll to ask "did the cursor
    /// move into a different measure?".
    var measureIndex: Int {
        switch self {
        case let .item(id): return id.measureIndex
        case let .beat(mi, _): return mi
        }
    }
}

extension LayoutDocument {
    /// Index of the system that contains the given measure. `nil` when no
    /// system holds that measure.
    func systemIndex(forMeasureIndex mi: Int) -> Int? {
        for (i, sys) in systems.enumerated()
            where sys.measures.contains(where: { $0.measureIndex == mi })
        {
            return i
        }
        return nil
    }
}

/// Identifier for vertical-mode auto-scroll targets. One anchor per system,
/// placed at the system's top Y in document space.
struct VerticalSystemAnchorID: Hashable {
    let systemIndex: Int
}

/// Per-system frame in the vertical scroll view's named coordinate space
/// (`"vScroll"`). Updated continuously as the user scrolls so the auto-
/// scroller can ask "is this system on screen *right now*?" without doing
/// scroll-offset arithmetic.
struct VerticalSystemFramesKey: PreferenceKey {
    static let defaultValue: [Int: CGRect] = [:]
    static func reduce(value: inout [Int: CGRect], nextValue: () -> [Int: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

/// Per-system invisible anchors stacked in a real `VStack` with spacers
/// sized to the document Y of each anchor. Two jobs:
///
///   * `ScrollViewReader.scrollTo(VerticalSystemAnchorID(systemIndex:),
///     anchor: .top | .bottom)` — snap a system's top staff to the
///     viewport top, or its bottom staff to the viewport bottom.
///   * `VerticalSystemFramesKey` preference — reports each anchor's live
///     frame in the named scroll-view coord space.
///
/// Each anchor view spans the system's *staff range* — top staff's top
/// through bottom staff's bottom. That makes alignment lock the cursor's
/// staff range to the viewport edge rather than including system whitespace.
struct VerticalSystemAnchors: View {
    let document: LayoutDocument

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(0 ..< document.systems.count, id: \.self) { i in
                let sys = document.systems[i]
                let topY = staffTopDocY(of: sys)
                let bottomY = staffBottomDocY(of: sys)
                let height = max(0, bottomY - topY)
                let prevBottom: CGFloat = i == 0
                    ? 0
                    : staffBottomDocY(of: document.systems[i - 1])
                let gap = max(0, topY - prevBottom)
                if gap > 0 {
                    Color.clear.frame(width: 1, height: gap)
                }
                Color.clear
                    .frame(width: 1, height: height)
                    .id(VerticalSystemAnchorID(systemIndex: i))
                    .background(
                        GeometryReader { g in
                            Color.clear.preference(
                                key: VerticalSystemFramesKey.self,
                                value: [i: g.frame(in: .named("vScroll"))]
                            )
                        }
                    )
            }
            Spacer(minLength: 0)
        }
        .frame(
            width: document.size.width,
            height: document.size.height,
            alignment: .topLeading
        )
        .allowsHitTesting(false)
    }

    private func staffTopDocY(of sys: LayoutSystem) -> CGFloat {
        sys.origin.y + (sys.staffOrigins.first?.y ?? 0)
    }

    private func staffBottomDocY(of sys: LayoutSystem) -> CGFloat {
        sys.origin.y
            + (sys.staffOrigins.last?.y ?? 0)
            + document.metrics.staffHeight
    }
}

// MARK: - Auto-scroll geometry helpers

/// Visibility test for an anchor frame in a scroll view's named coord space.
/// Treats the anchor as visible only when fully inside the viewport — any
/// partial overhang triggers a scroll. The exception: when the anchor is
/// taller than the viewport (nothing we can do), fall back to "any overlap"
/// so the heuristic doesn't oscillate between top and bottom alignment.
func isAnchorFullyVisible(
    anchorMin: CGFloat,
    anchorMax: CGFloat,
    anchorSize: CGFloat,
    viewportSize: CGFloat
) -> Bool {
    if anchorSize > viewportSize {
        return anchorMax > 0 && anchorMin < viewportSize
    }
    return anchorMin >= 0 && anchorMax <= viewportSize
}

/// Build a `UnitPoint` that, when passed to
/// `ScrollViewReader.scrollTo(_, anchor:)`, leaves `pad` points between the
/// anchor edge and the matching viewport edge.
///
/// `scrollTo` aligns the target's anchor point with the viewport's anchor
/// point. With `y_unit = y`:
///
///     scrollOffset = target.minY + y * (target.height - viewport.height)
///
/// To place `target.minY` at `pad` (top-aligned with `pad` inset):
///     y = pad / (viewport - target).
/// Bottom-aligned with `pad` inset is the mirror.
///
/// When the anchor is bigger than the viewport — or the room left after
/// padding would push the opposite edge off — fall back to plain
/// `.top` / `.bottom`.
func paddedScrollAnchor(
    aboveViewport: Bool,
    anchorSize: CGFloat,
    viewportSize: CGFloat,
    pad: CGFloat
) -> UnitPoint {
    let denom = viewportSize - anchorSize
    let frac: CGFloat = if denom <= pad {
        aboveViewport ? 0 : 1
    } else if aboveViewport {
        pad / denom
    } else {
        1 - pad / denom
    }
    return UnitPoint(x: 0.5, y: frac)
}
