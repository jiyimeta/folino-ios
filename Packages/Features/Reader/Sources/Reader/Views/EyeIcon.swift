import SwiftUI

struct EyeIcon: View {
    let isOpen: Bool
    var lineWidth: CGFloat

    private var openness: CGFloat {
        isOpen ? 1 : 0
    }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                eyeball(in: geo.size)
                pupil(in: geo.size)
            }
            .mask {
                EyeShape(openness: openness)
            }
            .overlay {
                EyeLowerCurve()
                    .stroke(lineWidth: lineWidth)
                    .padding(lineWidth / 2)
            }
        }
    }

    private func eyeball(in size: CGSize) -> some View {
        let fitted = fitSize(in: size)

        return Rectangle()
            .overlay {
                Circle()
                    .blendMode(.destinationOut)
                    .frame(
                        width: fitted.width * Constants.eyeballScale,
                        height: fitted.width * Constants.eyeballScale
                    )
                    .position(x: size.width / 2, y: size.height / 2)
            }
            .compositingGroup()
    }

    private func pupil(in size: CGSize) -> some View {
        let fitted = fitSize(in: size)

        return Circle()
            .frame(width: fitted.width * Constants.pupilScale)
            .position(x: size.width / 2, y: size.height / 2)
    }

    private func fitSize(in size: CGSize) -> CGSize {
        let base = CGSize(width: 100, height: 64)

        let scale = min(
            size.width / base.width,
            size.height / base.height
        )

        return CGSize(
            width: base.width * scale,
            height: base.height * scale
        )
    }
}

private struct EyeShape: Shape {
    var openness: CGFloat

    var animatableData: CGFloat {
        get { openness }
        set { openness = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let base = CGSize(width: 100, height: 64)

        let scale = min(
            rect.width / base.width,
            rect.height / base.height
        )

        let width = base.width * scale
        let height = base.height * scale

        let offsetX = (rect.width - width) / 2
        let offsetY = (rect.height - height) / 2

        let x = width * Constants.curveXRatio
        let y = height * Constants.curveYRatio
        let midY = offsetY + height / 2

        let topY = midY - y * (openness - 0.5) * 2

        return Path { path in
            path.move(to: CGPoint(x: offsetX, y: midY))

            path.addCurve(
                to: CGPoint(x: offsetX + width, y: midY),
                control1: CGPoint(x: offsetX + x, y: midY + y),
                control2: CGPoint(x: offsetX + width - x, y: midY + y)
            )

            path.addCurve(
                to: CGPoint(x: offsetX, y: midY),
                control1: CGPoint(x: offsetX + width - x, y: topY),
                control2: CGPoint(x: offsetX + x, y: topY)
            )
        }
    }
}

private struct EyeLowerCurve: Shape {
    func path(in rect: CGRect) -> Path {
        let base = CGSize(width: 100, height: 64)

        let scale = min(
            rect.width / base.width,
            rect.height / base.height
        )

        let width = base.width * scale
        let height = base.height * scale

        let offsetX = (rect.width - width) / 2
        let offsetY = (rect.height - height) / 2

        let x = width * Constants.curveXRatio
        let y = height * Constants.curveYRatio
        let midY = offsetY + height / 2

        return Path { path in
            path.move(to: CGPoint(x: offsetX, y: midY))

            path.addCurve(
                to: CGPoint(x: offsetX + width, y: midY),
                control1: CGPoint(x: offsetX + x, y: midY + y),
                control2: CGPoint(x: offsetX + width - x, y: midY + y)
            )
        }
    }
}

// MARK: - Constants

private enum Constants {
    static let curveXRatio: CGFloat = 0.19
    static let curveYRatio: CGFloat = 0.65
    static let eyeballScale: CGFloat = 0.41
    static let pupilScale: CGFloat = 0.15
}

#Preview {
    EyeIcon(isOpen: true, lineWidth: 2)
        .frame(width: 100, height: 100)
    EyeIcon(isOpen: false, lineWidth: 2)
        .frame(width: 100, height: 100)
}
