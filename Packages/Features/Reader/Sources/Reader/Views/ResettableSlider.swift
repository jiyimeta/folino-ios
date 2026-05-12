import SwiftUI

/// A Slider that exposes a "reset to default" affordance: a small tick at
/// the default position along the track, and a double-tap that snaps the
/// value back to that default.
///
/// Double-tap detection uses two independent paths so it works everywhere
/// on the slider:
///
/// - **Track / bar**: a SwiftUI `.simultaneousGesture(TapGesture(count: 2))`
///   on the slider catches it. The track has no internal gesture competing
///   for the touch, so this path fires cleanly.
/// - **Thumb**: the SwiftUI `TapGesture` is unreliable on the thumb because
///   the slider's internal drag-from-zero gesture often claims the touch
///   first. We watch the slider's `onEditingChanged` stream instead — two
///   consecutive editing-end events at the same value within a short window
///   are treated as a double-tap.
///
/// **Binding contract**: the caller must route `value` through a stable
/// reference type (e.g. an `@Observable` model with a transient drag-state
/// property — see `PlaybackMixerModel.setVolume` / `TempoModel.setMultiplier`).
/// SwiftUI Slider writes its internal thumb position back through the
/// binding on release; a plain `@State` target gets clobbered, undoing
/// the reset. Routing through a model lets `onReset` authoritatively
/// clear the transient state.
struct ResettableSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let defaultValue: Double
    var onEditingChanged: (Bool) -> Void = { _ in }
    var onReset: () -> Void = {}

    @State private var detector = ThumbTapDetector()

    var body: some View {
        Slider(
            value: $value,
            in: range,
            onEditingChanged: { editing in
                if !editing, detector.endTouchIsDoubleTap(at: value) {
                    reset()
                }
                onEditingChanged(editing)
            },
        )
        .overlay { tick }
        .simultaneousGesture(
            TapGesture(count: 2).onEnded { reset() },
        )
    }

    private func reset() {
        value = defaultValue
        onReset()
    }

    private var tick: some View {
        GeometryReader { proxy in
            let inset: CGFloat = 18
            let usable = max(0, proxy.size.width - inset * 2)
            let span = range.upperBound - range.lowerBound
            let frac = span > 0 ? (defaultValue - range.lowerBound) / span : 0
            let x = inset + usable * CGFloat(frac)
            Capsule()
                .fill(.tertiary)
                .frame(width: 2, height: 8)
                .position(x: x, y: proxy.size.height / 2)
        }
        .allowsHitTesting(false)
    }
}

/// Detects a double-tap on the slider thumb by inspecting the cadence of
/// `onEditingChanged(false)` events. Two end-of-editing events at the same
/// value within `tapWindow` seconds qualify — drag releases fail the
/// same-value check, lone taps fail the cadence check.
@MainActor
private final class ThumbTapDetector {
    private var lastEndTime: Date?
    private var lastEndValue: Double?

    private let tapWindow: TimeInterval = 0.4
    private let movementEpsilon = 0.001

    func endTouchIsDoubleTap(at value: Double) -> Bool {
        let now = Date()
        defer {
            lastEndTime = now
            lastEndValue = value
        }
        guard let prevTime = lastEndTime,
              let prevValue = lastEndValue,
              now.timeIntervalSince(prevTime) < tapWindow,
              abs(value - prevValue) < movementEpsilon
        else {
            return false
        }
        // Clear so a triple-tap doesn't fire reset twice.
        lastEndTime = nil
        lastEndValue = nil
        return true
    }
}

#if DEBUG
#Preview("Tick alignment (value == default)") {
    @Previewable @State var atZero = 0.0
    @Previewable @State var atHalf = 0.5
    @Previewable @State var atOne = 1.0
    @Previewable @State var atOff = 1.25
    Form {
        ResettableSlider(value: $atZero, range: 0 ... 1, defaultValue: 0.0)
        ResettableSlider(value: $atHalf, range: 0 ... 1, defaultValue: 0.5)
        ResettableSlider(value: $atOne, range: 0 ... 1, defaultValue: 1.0)
        ResettableSlider(value: $atOff, range: 0.5 ... 2.0, defaultValue: 1.0)
    }
}
#endif
