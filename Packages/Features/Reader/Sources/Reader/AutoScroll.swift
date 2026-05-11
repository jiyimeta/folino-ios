import CoreGraphics
import SheetMusicCore
import SheetMusicLayout
import SwiftUI

extension ScoreCursor {
    /// Measure index this cursor is parked on, regardless of `.item`
    /// vs `.beat` flavour. Used by horizontal-mode auto-scroll to ask
    /// "did the cursor move into a different measure?".
    var measureIndex: Int {
        switch self {
        case let .item(id): id.measureIndex
        case let .beat(mi, _): mi
        }
    }
}

/// Identifier for horizontal-mode auto-scroll targets. One anchor
/// per measure, placed at the measure's leading X in document space.
struct HorizontalMeasureAnchorID: Hashable {
    let measureIndex: Int
}

/// Per-measure frame in the horizontal scroll view's named coord
/// space (`"hScroll"`). Updated continuously as the user scrolls so
/// the auto-scroller can ask "is this measure on screen *right
/// now*?" without doing scroll-offset arithmetic.
struct HorizontalMeasureFramesKey: PreferenceKey {
    static let defaultValue: [Int: CGRect] = [:]
    static func reduce(
        value: inout [Int: CGRect],
        nextValue: () -> [Int: CGRect],
    ) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

/// Per-measure invisible anchors stacked in a real `HStack`. Each
/// anchor is sized to the measure's full width so its preference-
/// reported frame in `.named("hScroll")` *is* the measure's live
/// rect, and `ScrollViewReader.scrollTo(_, anchor:)` can snap it to
/// the viewport's leading or trailing edge.
struct HorizontalMeasureAnchors: View {
    let document: LayoutDocument

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            ForEach(0 ..< measures.count, id: \.self) { i in
                let m = measures[i]
                let prevRight: CGFloat = i == 0
                    ? 0
                    : measures[i - 1].docX + measures[i - 1].width
                let gap = max(0, m.docX - prevRight)
                if gap > 0 {
                    Color.clear.frame(width: gap, height: 1)
                }
                Color.clear
                    .frame(width: m.width, height: 1)
                    .id(HorizontalMeasureAnchorID(
                        measureIndex: m.measureIndex,
                    ))
                    .background(
                        GeometryReader { g in
                            Color.clear.preference(
                                key: HorizontalMeasureFramesKey.self,
                                value: [
                                    m.measureIndex:
                                        g.frame(in: .named("hScroll")),
                                ],
                            )
                        },
                    )
            }
            Spacer(minLength: 0)
        }
        .frame(
            width: document.size.width,
            height: document.size.height,
            alignment: .topLeading,
        )
        .allowsHitTesting(false)
    }

    private var measures: [(measureIndex: Int, docX: CGFloat, width: CGFloat)] {
        var seen: Set<Int> = []
        var result: [(measureIndex: Int, docX: CGFloat, width: CGFloat)] = []
        for sys in document.systems {
            for m in sys.measures
                where seen.insert(m.measureIndex).inserted
            {
                result.append((
                    measureIndex: m.measureIndex,
                    docX: sys.origin.x + m.origin.x,
                    width: m.width,
                ))
            }
        }
        return result.sorted { $0.docX < $1.docX }
    }
}

/// Visibility test for an anchor frame in a scroll view's named
/// coord space. Treats the anchor as visible only when fully inside
/// the viewport — any partial overhang triggers a scroll. The
/// exception: when the anchor is wider than the viewport (nothing
/// we can do), fall back to "any overlap" so the auto-scroll
/// heuristic doesn't oscillate between leading and trailing
/// alignment on every cursor step.
func isAnchorFullyVisible(
    anchorMin: CGFloat,
    anchorMax: CGFloat,
    anchorSize: CGFloat,
    viewportSize: CGFloat,
) -> Bool {
    if anchorSize > viewportSize {
        return anchorMax > 0 && anchorMin < viewportSize
    }
    return anchorMin >= 0 && anchorMax <= viewportSize
}

/// Build a `UnitPoint` that, when passed to
/// `ScrollViewReader.scrollTo(_, anchor:)`, leaves `pad` points
/// between the anchor edge and the matching viewport edge.
func paddedScrollAnchor(
    aboveViewport: Bool,
    anchorSize: CGFloat,
    viewportSize: CGFloat,
    pad: CGFloat,
    horizontal: Bool,
) -> UnitPoint {
    let denom = viewportSize - anchorSize
    let frac: CGFloat = if denom <= pad {
        aboveViewport ? 0 : 1
    } else if aboveViewport {
        pad / denom
    } else {
        1 - pad / denom
    }
    return horizontal
        ? UnitPoint(x: frac, y: 0.5)
        : UnitPoint(x: 0.5, y: frac)
}
