import Domain
import Foundation
import SwiftUI

/// The A4 pitch-calibration row of the playback inspector. Split into its own file to keep
/// `PlaybackInspectorScreen` under the file-length budget. Laid out like the tempo row: a
/// "A4 = NNNHz" readout + whole-hertz ± stepper on top, and a global-relative readout + slider below.
extension PlaybackInspectorScreen {
    /// Snap detents + radius for the A4 slider: a release within 1 Hz of 432 or 440 snaps to that value.
    private var a4SnapDetents: [Double] {
        [432, 440]
    }

    private var a4SnapRadius: Double {
        1.0
    }

    @ViewBuilder
    var a4ReferenceRow: some View {
        let hz = a4ReferenceModel.displayHz
        let globalHz = a4ReferenceModel.globalDefaultHz
        HStack(spacing: 8) {
            Image(systemName: "tuningfork")
                .foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 4) {
                a4ReadoutLine(hz: hz)
                a4SliderLine(globalHz: globalHz)
            }
        }
    }

    /// Top line: the "A4 = NNNHz" readout and a whole-hertz ± stepper. Mirrors `tempoReadoutLine`.
    @ViewBuilder
    private func a4ReadoutLine(hz: Double) -> some View {
        // One notch = one whole hertz; stepping from the inherited global value creates a per-score override.
        let stepperHz = Binding<Double>(
            get: { a4ReferenceModel.displayHz.rounded() },
            set: { newValue in
                let clamped = A4Reference.clamp(newValue.rounded())
                Task { await a4ReferenceModel.commitValue(clamped) }
            },
        )
        HStack(spacing: 8) {
            Text(verbatim: "A4 = \(Int(hz.rounded()))Hz")
                .font(.callout.monospacedDigit())
                .foregroundStyle(.primary)
                .contentTransition(.numericText(value: hz))
            Spacer()
            Stepper(value: stepperHz, in: A4Reference.minHz ... A4Reference.maxHz, step: 1) {
                EmptyView()
            }
            .labelsHidden()
            .fixedSize()
        }
    }

    /// Bottom line: the global-relative readout ("440Hz +8セント") and a whole-hertz slider. Double-tap the slider to
    /// clear the per-score override and fall back to the global default. Mirrors `tempoSliderLine`.
    @ViewBuilder
    private func a4SliderLine(globalHz: Double) -> some View {
        let hzBinding = Binding<Double>(
            get: { a4ReferenceModel.displayHz },
            set: { a4ReferenceModel.setValue($0) },
        )
        HStack(spacing: 8) {
            ZStack(alignment: .leading) {
                // Reserve the widest possible readout (3-digit Hz, signed 3-digit cents) so the slider's leading
                // edge never shifts as the value changes. `monospacedDigit` keeps every digit the same width.
                Text(verbatim: a4RelativeReadoutSizingText())
                    .hidden()
                Text(verbatim: a4RelativeToGlobalText(currentHz: hzBinding.wrappedValue, globalHz: globalHz))
            }
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.secondary)
            ResettableSlider(
                value: hzBinding,
                range: A4Reference.minHz ... A4Reference.maxHz,
                defaultValue: A4Reference.standardHz,
                step: 1,
                onEditingChanged: { editing in
                    guard !editing else { return }
                    let snapped = a4SnapDetents.first { abs(hzBinding.wrappedValue - $0) <= a4SnapRadius }
                        ?? hzBinding.wrappedValue
                    Task { await a4ReferenceModel.commitValue(snapped.rounded()) }
                },
                onReset: { Task { await a4ReferenceModel.resetValue() } },
            )
        }
    }

    /// Secondary readout: the global default plus the current value's cents offset from it, e.g. "440Hz +8セント".
    /// At the global default the offset reads "±0". Sign string, unit, and number/unit spacing are localized.
    private func a4RelativeToGlobalText(currentHz: Double, globalHz: Double) -> String {
        let global = Int(globalHz.rounded())
        let cents = Int((A4Reference.cents(forHz: currentHz) - A4Reference.cents(forHz: globalHz)).rounded())
        let signed = cents == 0 ? "±0" : String(format: "%+d", cents)
        let format = String(localized: "reader.inspector.a4Reference.relativeToGlobal", bundle: .module)
        return String(format: format, global, signed)
    }

    /// Widest readout the row can show — 3-digit Hz + signed 3-digit cents — used (hidden) to pin the column width
    /// so the slider never reflows. Digit count, not value, drives the width under `monospacedDigit`.
    private func a4RelativeReadoutSizingText() -> String {
        let format = String(localized: "reader.inspector.a4Reference.relativeToGlobal", bundle: .module)
        return String(format: format, 888, "-888")
    }
}
