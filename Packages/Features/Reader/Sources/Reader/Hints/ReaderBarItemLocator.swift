import SwiftUI
import UIKit

/// Finds where the navigation bar's item controls actually are, in window coordinates.
///
/// This exists because a bar item cannot answer the question itself. Measured on iOS 26: SwiftUI's
/// `frame(in: .global)` inside a `ToolbarItem` returns the item's own bounds centred on the origin — every item
/// reports (-13, -13, 26, 27)-ish, carrying no position at all; a `UIViewRepresentable` planted in the item never
/// gets a window; nothing in the bar's view tree carries the `accessibilityIdentifier` the item was given; and
/// `UINavigationBar.topItem.rightBarButtonItems` is EMPTY, because SwiftUI drives the bar through its own plumbing
/// rather than through `UIBarButtonItem`s. What is left is the rendered hierarchy, which is real and measurable.
///
/// So this reads geometry only, and never asks what anything IS:
///
/// * no private class names — items are recognised by size and containment, not by `_UIButtonBarButton`;
/// * no OS-version branches — iOS 18's `UIButton`-in-a-bar and iOS 26's glass platters both come out as one cluster
///   of overlapping views per control, and the union of a cluster is the control's frame either way;
/// * no assumption about how many items there are, or what they are — callers match by POSITION (see
///   `ReaderHintCoordinator.refreshBarAnchors`), counting from whichever edge the item is pinned to.
///
/// Counting from the trailing edge is what makes the result stable: when the bar runs out of room, iOS folds items
/// into an overflow menu from the LOW-priority end, which is the leading end of the trailing group — so the rightmost
/// items keep their order and their ordinals whatever else happens.
@MainActor
enum ReaderBarItemLocator {
    /// One navigation bar's measurements, all in window coordinates.
    struct BarItems {
        let bar: CGRect
        /// Item frames in visual order, left to right.
        let items: [CGRect]
    }

    /// Measures the navigation bar serving `region` — the on-screen area of the screen asking, which is what picks
    /// the right bar when several are on screen at once (an iPad split view has one per column).
    static func itemFrames(servingRegionInWindow region: CGRect) -> BarItems? {
        guard let window = keyWindow else { return nil }
        guard let bar = navigationBar(in: window, serving: region) else { return nil }
        let barFrame = bar.convert(bar.bounds, to: window)
        let items = cluster(candidates(in: bar, barFrame: barFrame, window: window))
        guard !items.isEmpty else { return nil }
        return BarItems(bar: barFrame, items: items)
    }

    // MARK: - Bar

    private static var keyWindow: UIWindow? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first { $0.isKeyWindow }
    }

    /// The visible bar whose horizontal span overlaps `region` most. Width overlap rather than containment because a
    /// bar is as wide as its column, and the asking region is that column's content.
    private static func navigationBar(in window: UIWindow, serving region: CGRect) -> UINavigationBar? {
        var bars: [(bar: UINavigationBar, frame: CGRect)] = []
        walk(window) { view in
            guard let bar = view as? UINavigationBar, !bar.isHidden, bar.alpha > 0.01 else { return }
            let frame = bar.convert(bar.bounds, to: window)
            guard frame.width > 0, frame.height > 0 else { return }
            bars.append((bar, frame))
        }
        guard !bars.isEmpty else { return nil }
        guard region.width > 0 else { return bars.first?.bar }
        return bars
            .map { ($0.bar, overlapWidth($0.frame, region)) }
            .filter { $0.1 > 0 }
            .max { $0.1 < $1.1 }?.0
            ?? bars.first?.bar
    }

    private static func overlapWidth(_ lhs: CGRect, _ rhs: CGRect) -> CGFloat {
        max(0, min(lhs.maxX, rhs.maxX) - max(lhs.minX, rhs.minX))
    }

    // MARK: - Items

    /// Every view inside the bar that is shaped like a control: small enough not to be the bar's background or its
    /// title, big enough not to be a hairline or a badge, and drawn within the bar itself.
    private static func candidates(in bar: UINavigationBar, barFrame: CGRect, window: UIWindow) -> [CGRect] {
        var frames: [CGRect] = []
        walk(bar) { view in
            guard view !== bar, !view.isHidden, view.alpha > 0.01 else { return }
            let frame = view.convert(view.bounds, to: window)
            guard frame.width >= Metrics.minSide, frame.width <= Metrics.maxWidth,
                  frame.height >= Metrics.minSide, frame.height <= Metrics.maxHeight,
                  barFrame.insetBy(dx: -Metrics.slack, dy: -Metrics.slack).contains(frame)
            else { return }
            frames.append(frame)
        }
        return frames
    }

    /// Collapses the stack of views each control is built from — platter, glass, container, button, glyph — into one
    /// frame per control, by merging views that sit substantially on top of each other.
    ///
    /// "Substantially" and not "at all": the pieces of one control are near-concentric, overlapping almost entirely,
    /// while two neighbouring controls are side by side. Merging on any overlap at all would fuse two real items into
    /// one the moment a rounded frame put them a fraction of a point into each other — and a fused pair silently
    /// shifts every ordinal counted past it, which is the one failure this whole mechanism must not have.
    static func cluster(_ frames: [CGRect]) -> [CGRect] {
        var clusters: [CGRect] = []
        for frame in frames.sorted(by: { $0.minX < $1.minX }) {
            let overlap = clusters.last.map { overlapWidth($0, frame) } ?? 0
            if let last = clusters.last, overlap >= Metrics.mergeFraction * min(last.width, frame.width) {
                clusters[clusters.count - 1] = last.union(frame)
            } else {
                clusters.append(frame)
            }
        }
        return clusters
    }

    private enum Metrics {
        /// Below this is a separator, a badge, or a glyph detail rather than a control.
        static let minSide: CGFloat = 18
        /// Above this is the bar's background, its title, or a large-title container.
        static let maxWidth: CGFloat = 96
        static let maxHeight: CGFloat = 64
        /// Controls can be drawn a couple of points outside the bar's own bounds (a pressed platter grows).
        static let slack: CGFloat = 8
        /// How much two frames must share, relative to the narrower one, to count as parts of the same control.
        static let mergeFraction: CGFloat = 0.5
    }

    private static func walk(_ view: UIView, _ visit: (UIView) -> Void) {
        visit(view)
        for subview in view.subviews {
            walk(subview, visit)
        }
    }
}
