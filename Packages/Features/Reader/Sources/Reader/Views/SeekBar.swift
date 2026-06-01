import SwiftUI

/// Apple Music-style scrubber: a thumbless progress track that seeks by drag *delta* rather than to the touch
/// position. Touching anywhere and moving horizontally shifts the position by the dragged fraction of the track width
/// — a tap with no movement does nothing. The track thickens slightly while scrubbing for feedback.
///
/// `fraction` is the position to display (0...1); the owner supplies it from the live playback cursor when idle and
/// from the in-progress scrub value while dragging. The callbacks let the owner drive its scrub state machine:
/// `onScrubBegan` once at touch-down, `onScrubChanged` with each new absolute fraction, `onScrubEnded` at release.
struct SeekBar: View {
    let fraction: Double
    let onScrubBegan: () -> Void
    let onScrubChanged: (Double) -> Void
    let onScrubEnded: () -> Void

    /// Non-nil while a drag is active; holds the fraction captured at touch-down so movement is applied as a delta.
    @State private var dragStartFraction: Double?

    private var isScrubbing: Bool {
        dragStartFraction != nil
    }

    private static let idleHeight: CGFloat = 6
    private static let activeHeight: CGFloat = 10
    /// Total row height, sized for the active track plus a comfortable touch target around the thin idle track.
    private static let rowHeight: CGFloat = 28

    var body: some View {
        let progress = min(max(fraction, 0), 1)
        GeometryReader { geometry in
            let width = geometry.size.width
            ZStack(alignment: .leading) {
                Capsule().fill(.primary.opacity(0.15))
                Capsule().fill(.primary.opacity(0.45)).frame(width: width * progress)
            }
            .frame(height: isScrubbing ? Self.activeHeight : Self.idleHeight)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        if dragStartFraction == nil {
                            dragStartFraction = progress
                            onScrubBegan()
                        }
                        let start = dragStartFraction ?? progress
                        let delta = width > 0 ? value.translation.width / width : 0
                        onScrubChanged(min(max(start + delta, 0), 1))
                    }
                    .onEnded { _ in
                        dragStartFraction = nil
                        onScrubEnded()
                    },
            )
            .animation(.easeOut(duration: 0.15), value: isScrubbing)
        }
        .frame(height: Self.rowHeight)
        .accessibilityElement()
        .accessibilityLabel(Text("reader.toolbar.seekBar", bundle: .module))
        .accessibilityValue(Text(verbatim: "\(Int((progress * 100).rounded()))%"))
        .accessibilityAdjustableAction { direction in
            let step = 0.05
            let target = direction == .increment ? min(progress + step, 1) : max(progress - step, 0)
            onScrubBegan()
            onScrubChanged(target)
            onScrubEnded()
        }
    }
}

#if DEBUG
#Preview("Seek bar") {
    @Previewable @State var fraction = 0.35
    return VStack(spacing: 40) {
        SeekBar(
            fraction: fraction,
            onScrubBegan: {},
            onScrubChanged: { fraction = $0 },
            onScrubEnded: {},
        )
        Text(verbatim: "\(Int(fraction * 100))%")
    }
    .padding(40)
}
#endif
