import SwiftUI

/// A ±1-measure skip glyph: the stock circular skip arrow (`gobackward` / `goforward`, drawn without a number) with a
/// small "m" composited in the center — the look of `gobackward.5` but for measures.
///
/// Ported from VocalTuner so the two apps' measure-skip controls match.
struct MeasureSkipSymbol: View {
    enum Direction { case backward, forward }
    let direction: Direction
    var fontSize: CGFloat = 22

    var body: some View {
        Image(systemName: direction == .backward ? "gobackward" : "goforward")
            .font(.system(size: fontSize))
            .overlay(
                Text(verbatim: "m")
                    .font(.system(size: fontSize * 0.42, weight: .semibold))
                    .offset(y: fontSize * 0.06),
            )
    }
}
