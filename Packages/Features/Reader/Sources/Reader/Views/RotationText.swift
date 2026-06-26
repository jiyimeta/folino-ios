import SwiftUI

/// A single line of text that, when it overflows its width, fades at both edges and slowly scrolls horizontally
/// ("rotates") on a loop — and otherwise stays put (optionally centered). Used for the transport card's score-title
/// line so a long name doesn't collide with the time labels.
///
/// Ported from VocalTuner so the two apps' transport titles behave identically.
struct RotationText: View {
    var title: String
    var isCenterAligned = false

    let fadeWidth: CGFloat = 8
    let longTextSpacing: CGFloat = 34

    @State private var textWidth: CGFloat = 0
    @State private var textHeight: CGFloat = 0
    @State private var isRotated = false

    @State private var rotationTask: Task<Void, Never>?

    var body: some View {
        GeometryReader { geometry in
            HStack(spacing: textWidth > geometry.size.width ? longTextSpacing : textWidth + geometry.size.width) {
                Text(title)
                    .lineLimit(1)
                    .onGeometryChange(for: CGSize.self, of: \.size) { newValue in
                        textWidth = newValue.width
                        textHeight = newValue.height
                        resetRotation(frameWidth: geometry.size.width)
                    }
                    .offset(
                        x: textWidth < geometry.size.width && isCenterAligned
                            ? geometry.size.width / 2 - textWidth / 2
                            : 0,
                    )

                Text(title)
                    .lineLimit(1)
            }
            .fixedSize(horizontal: true, vertical: false)
            .offset(x: isRotated && textWidth > geometry.size.width ? -textWidth - longTextSpacing : 0)
            .frame(width: geometry.size.width, alignment: .leading)
            .fadeHorizontalOverflow(by: fadeWidth)
        }
        .onGeometryChange(for: CGFloat.self, of: \.size.width) { newValue in
            resetRotation(frameWidth: newValue)
        }
        .frame(height: textHeight > 0 ? textHeight : nil)
    }

    private func resetRotation(frameWidth: CGFloat) {
        rotationTask?.cancel()
        isRotated = false
        rotationTask = Task {
            withAnimation(.linear(duration: 0.03 * textWidth).delay(2).repeatForever(autoreverses: false)) {
                isRotated = textWidth > frameWidth
            }
        }
    }
}

extension View {
    func fadeHorizontalOverflow(by value: CGFloat) -> some View {
        GeometryReader { geometry in
            self
                .padding(.horizontal, value)
                .mask {
                    LinearGradient(
                        stops: [
                            Gradient.Stop(color: .clear, location: 0),
                            Gradient.Stop(color: .black, location: value / geometry.size.width),
                            Gradient.Stop(color: .black, location: 1 - value / geometry.size.width),
                            Gradient.Stop(color: .clear, location: 1),
                        ],
                        startPoint: .leading,
                        endPoint: .trailing,
                    )
                }
                .padding(.horizontal, -value)
        }
    }
}
