import SwiftUI

/// Identifies the four page-navigation slices in `TapOverlay` so each one can render the right icon / label combo
/// when pressed without duplicating that map at every caller.
enum PageTapZoneKind {
    case first
    case last
    case previous
    case next

    /// `first` ships a custom symbol bundled with the Reader module (no system SF Symbol matches the
    /// `arrow.uturn.backward.to.line` glyph). Everything else maps to a system symbol.
    var image: Image {
        switch self {
        case .first: Image("arrow.uturn.backward.to.line", bundle: .module)
        case .last: Image(systemName: "arrow.forward.to.line")
        case .previous: Image(systemName: "arrow.uturn.backward")
        case .next: Image(systemName: "arrow.forward")
        }
    }

    var labelKey: LocalizedStringKey {
        switch self {
        case .first: "reader.pageMode.tapZone.first"
        case .last: "reader.pageMode.tapZone.last"
        case .previous: "reader.pageMode.tapZone.previous"
        case .next: "reader.pageMode.tapZone.next"
        }
    }

    /// Per-corner radii for the highlight pill. The side running along the screen edge stays square; the inner side
    /// rounds off so the highlight reads as a tab tucked against the edge rather than a free-floating chip.
    func cornerRadii(radius: CGFloat) -> RectangleCornerRadii {
        switch self {
        case .first, .previous:
            RectangleCornerRadii(
                topLeading: 0,
                bottomLeading: 0,
                bottomTrailing: radius,
                topTrailing: radius,
            )
        case .last, .next:
            RectangleCornerRadii(
                topLeading: radius,
                bottomLeading: radius,
                bottomTrailing: 0,
                topTrailing: 0,
            )
        }
    }
}

/// Page-turn tap zone that fires `action` on release inside the zone. `DragGesture(minimumDistance: 0)` drives press
/// tracking via `@GestureState` (auto-resets on lift/cancel) and decides whether the release counts as a tap by
/// checking the final location.
///
/// The highlight (translucent accent fill + icon + label) is driven by the externally-supplied `highlighted` flag, not
/// the zone's own gesture state. The parent collects press state from all zones and feeds the same flag back to each
/// one so a tap on any zone lights up the whole set in unison.
private struct PageTapZone: View {
    let kind: PageTapZoneKind
    let width: CGFloat
    let height: CGFloat
    let action: () -> Void
    let highlighted: Bool
    /// When true, render the onboarding hint (dashed border + light accent fill + tinted icon/label). Mutually
    /// exclusive with `highlighted` — the moment a finger lands the parent flips `hintVisible` false and `highlighted`
    /// true.
    let hintVisible: Bool
    let onPressChange: (Bool) -> Void

    @GestureState private var isPressed = false

    var body: some View {
        let shape = UnevenRoundedRectangle(cornerRadii: kind.cornerRadii(radius: 12))
        ZStack {
            // Onboarding hint layer: dashed border + light tint fill + tinted icon/label.
            ZStack {
                shape.fill(Color.accentColor.opacity(0.12))
                shape.strokeBorder(
                    Color.accentColor,
                    style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]),
                )
                zoneLabel
                    .foregroundStyle(Color.accentColor)
            }
            .opacity(hintVisible ? 1 : 0)
            .animation(.easeOut(duration: 0.2), value: hintVisible)

            // Press-feedback layer: solid grey fill + white icon/label. Resident at full strength so rapid re-taps
            // can't stack a fading-out copy under a fading-in copy and darken the fill.
            ZStack {
                shape.fill(Color.secondary.opacity(0.5))
                zoneLabel
                    .foregroundStyle(.white)
            }
            .opacity(highlighted ? 1 : 0)
            // Picking the animation off the *new* value keeps appearance instant (nil animation) and disappearance
            // smooth. The `delay(0.35)` keeps the highlight visible after the page has already turned, so the user
            // can see *which* tap zone fired before it disappears.
            .animation(
                highlighted ? nil : .easeOut(duration: 0.3).delay(0.35),
                value: highlighted,
            )
        }
        .frame(width: width, height: height)
        // Hit area stays a full rectangle so the square (screen-edge) corners remain tappable even though the pill
        // crops them visually.
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .updating($isPressed) { _, state, _ in state = true }
                .onEnded { value in
                    let bounds = CGRect(x: 0, y: 0, width: width, height: height)
                    // Inclusive of the trailing / bottom edge. A release on the right "next" column (against the
                    // screen edge) clamps to x == width, which fails the half-open `CGRect.contains` (`x < maxX`) and
                    // was silently dropped — the intermittent "edge tap does nothing". Treat the exact max edge as
                    // inside so a screen-edge tap counts.
                    let loc = value.location
                    let inside = loc.x >= bounds.minX && loc.x <= bounds.maxX
                        && loc.y >= bounds.minY && loc.y <= bounds.maxY
                    if inside { action() }
                },
        )
        .onChange(of: isPressed) { _, new in onPressChange(new) }
    }

    private var zoneLabel: some View {
        VStack(spacing: 6) {
            kind.image
                .font(.title2)
                .bold()
            Text(kind.labelKey, bundle: .module)
                .font(.caption)
                .fontWeight(.medium)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 4)
    }
}

/// Four-zone page-navigation overlay used by `PagedZoomedSurface`. Owns the shared press state so any active touch
/// lights up every zone in unison — that uniform highlight is the real surface the preview at the bottom of this file
/// exercises.
///
/// `leadingExtra` / `trailingExtra` widen the leading / trailing columns outward so the tap-active (and visually
/// highlighted) area can reach beyond `viewport` to the host's edges. The page-band internals still anchor to
/// `viewport`; only the edge columns absorb the safe-area gutters.
struct TapOverlay: View {
    let viewport: CGSize
    let leadingExtra: CGFloat
    let trailingExtra: CGFloat
    let onFirstPage: () -> Void
    let onPrevPage: () -> Void
    let onLastPage: () -> Void
    let onNextPage: () -> Void
    /// 1-indexed page number shown in the indicator badge.
    let currentPageNumber: Int
    /// Total page count shown in the indicator badge.
    let totalPages: Int
    /// When true, the four zones render a dashed-border onboarding hint at rest. Flips false the moment the user
    /// touches any zone.
    let showsHint: Bool
    /// Fires once per touch-down sequence — the parent uses this to flip the persisted dismiss flag.
    let onAnyZoneTouchDown: () -> Void

    /// Per-zone press state. Seeded from `initialPressedKinds` so previews can render the highlighted layout without
    /// firing a real gesture.
    @State private var pressedKinds: Set<PageTapZoneKind>

    init(
        viewport: CGSize,
        leadingExtra: CGFloat = 0,
        trailingExtra: CGFloat = 0,
        onFirstPage: @escaping () -> Void,
        onPrevPage: @escaping () -> Void,
        onLastPage: @escaping () -> Void,
        onNextPage: @escaping () -> Void,
        currentPageNumber: Int = 1,
        totalPages: Int = 1,
        showsHint: Bool = false,
        onAnyZoneTouchDown: @escaping () -> Void = {},
        initialPressedKinds: Set<PageTapZoneKind> = [],
    ) {
        self.viewport = viewport
        self.leadingExtra = leadingExtra
        self.trailingExtra = trailingExtra
        self.onFirstPage = onFirstPage
        self.onPrevPage = onPrevPage
        self.onLastPage = onLastPage
        self.onNextPage = onNextPage
        self.currentPageNumber = currentPageNumber
        self.totalPages = totalPages
        self.showsHint = showsHint
        self.onAnyZoneTouchDown = onAnyZoneTouchDown
        _pressedKinds = State(initialValue: initialPressedKinds)
    }

    var body: some View {
        // iPad narrows each column to a compact fixed width so the score's edge notes (inset by a matching margin in
        // `PagedScoreContainer`) clear the zone and stay tap-to-seek; iPhone keeps the original 12 % column.
        let baseColumnWidth = ReaderScoreLayout.pageTapZoneWidth(viewportWidth: viewport.width)
        let leadingColumnWidth = baseColumnWidth + leadingExtra
        let trailingColumnWidth = baseColumnWidth + trailingExtra
        let middleWidth = viewport.width - baseColumnWidth * 2
        let totalWidth = viewport.width + leadingExtra + trailingExtra
        let topHeight = viewport.height * 0.3
        let bottomHeight = viewport.height - topHeight
        let highlighted = !pressedKinds.isEmpty
        // Hint is mutually exclusive with the press visual.
        let hintVisible = showsHint && pressedKinds.isEmpty
        ZStack(alignment: .bottom) {
            HStack(spacing: 0) {
                edgeColumn(
                    width: leadingColumnWidth,
                    topHeight: topHeight,
                    bottomHeight: bottomHeight,
                    topKind: .first,
                    bottomKind: .previous,
                    topAction: onFirstPage,
                    bottomAction: onPrevPage,
                    highlighted: highlighted,
                    hintVisible: hintVisible,
                )
                Color.clear
                    .frame(width: middleWidth)
                    .allowsHitTesting(false)
                edgeColumn(
                    width: trailingColumnWidth,
                    topHeight: topHeight,
                    bottomHeight: bottomHeight,
                    topKind: .last,
                    bottomKind: .next,
                    topAction: onLastPage,
                    bottomAction: onNextPage,
                    highlighted: highlighted,
                    hintVisible: hintVisible,
                )
            }

            // Capsule badge mirroring the tap-zone highlight. Kept resident (opacity-gated rather than `if`-gated) so
            // its `current` updates while still visible — the page index changes the moment the finger lifts, and we
            // want the number it shows to be the *new* page from t=0 instead of the previous value frozen in place.
            PageIndicatorBadge(
                current: currentPageNumber,
                total: totalPages,
            )
            .padding(.bottom, 24)
            .opacity(highlighted ? 1 : 0)
            .allowsHitTesting(false)
        }
        .frame(width: totalWidth, height: viewport.height, alignment: .topLeading)
        // Local `.animation` only covers what doesn't already carry its own — i.e. the badge's insert / remove
        // transition. Each `PageTapZone` has its own `.animation(_:value:)`.
        .animation(
            highlighted ? nil : .easeOut(duration: 0.3).delay(0.35),
            value: highlighted,
        )
    }

    /// One leading / trailing tap column split 3 : 7 vertically.
    private func edgeColumn(
        width: CGFloat,
        topHeight: CGFloat,
        bottomHeight: CGFloat,
        topKind: PageTapZoneKind,
        bottomKind: PageTapZoneKind,
        topAction: @escaping () -> Void,
        bottomAction: @escaping () -> Void,
        highlighted: Bool,
        hintVisible: Bool,
    ) -> some View {
        VStack(spacing: 8) {
            PageTapZone(
                kind: topKind,
                width: width,
                height: topHeight,
                action: topAction,
                highlighted: highlighted,
                hintVisible: hintVisible,
                onPressChange: { updatePressed(topKind, pressed: $0) },
            )
            PageTapZone(
                kind: bottomKind,
                width: width,
                height: bottomHeight,
                action: bottomAction,
                highlighted: highlighted,
                hintVisible: hintVisible,
                onPressChange: { updatePressed(bottomKind, pressed: $0) },
            )
        }
    }

    /// Fires `onAnyZoneTouchDown` exactly once per touch-down sequence — the first transition from "no zones pressed"
    /// to "any zone pressed". A long press or a finger-roll between zones does not refire.
    private func updatePressed(_ kind: PageTapZoneKind, pressed: Bool) {
        if pressed {
            if pressedKinds.isEmpty { onAnyZoneTouchDown() }
            pressedKinds.insert(kind)
        } else {
            pressedKinds.remove(kind)
        }
    }
}

/// `n / d` page-position pill shown at the bottom of the page band while a tap zone is held. Matches the tap-zone
/// highlight fill so the navigation feedback reads as one piece.
private struct PageIndicatorBadge: View {
    let current: Int
    let total: Int

    var body: some View {
        Text(verbatim: "\(current) / \(total)")
            .font(.subheadline.monospacedDigit())
            .fontWeight(.medium)
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .background(Capsule().fill(Color.secondary.opacity(0.46)))
    }
}

// Renders the production `TapOverlay` with its highlight state pre-seeded so every zone shows its icon + label. The
// page band is sampled from the actual device canvas via `GeometryReader` so the tap zones really do start at the
// device's leading / trailing edge. Set `leadingGutter` / `trailingGutter` to mock the safe-area gutters that
// `pageInsets` contributes in landscape.
#Preview("Tap zones · no gutters") {
    TapZonePreviewHost(leadingGutter: 0, trailingGutter: 0)
        .ignoresSafeArea()
}

#Preview("Tap zones · landscape gutters") {
    TapZonePreviewHost(leadingGutter: 59, trailingGutter: 59)
        .ignoresSafeArea()
}

#Preview("Tap zones · onboarding hint") {
    TapZonePreviewHost(leadingGutter: 0, trailingGutter: 0, showsHint: true)
        .ignoresSafeArea()
}

private struct TapZonePreviewHost: View {
    let leadingGutter: CGFloat
    let trailingGutter: CGFloat
    /// When true, render the onboarding hint at rest (no pressed zones). Mutually exclusive with the highlighted
    /// press state.
    var showsHint = false

    var body: some View {
        GeometryReader { proxy in
            let totalWidth = proxy.size.width
            let viewportWidth = max(totalWidth - leadingGutter - trailingGutter, 0)
            let viewport = CGSize(width: viewportWidth, height: proxy.size.height)
            ZStack(alignment: .topLeading) {
                // Stripes mark where the safe-area gutters fall so it's visible that the tap zones overlap them.
                HStack(spacing: 0) {
                    Color.gray.opacity(0.25)
                        .frame(width: leadingGutter)
                    Color.white
                        .frame(width: viewportWidth)
                    Color.gray.opacity(0.25)
                        .frame(width: trailingGutter)
                }
                TapOverlay(
                    viewport: viewport,
                    leadingExtra: leadingGutter,
                    trailingExtra: trailingGutter,
                    onFirstPage: {},
                    onPrevPage: {},
                    onLastPage: {},
                    onNextPage: {},
                    showsHint: showsHint,
                    initialPressedKinds: showsHint ? [] : [.first],
                )
            }
        }
    }
}
