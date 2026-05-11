import Domain
import SwiftUI

struct RepeatModePicker: View {
    @Binding var selection: RepeatMode

    var body: some View {
        Picker("", selection: $selection) {
            ForEach(RepeatMode.allCases, id: \.self) { mode in
                icon(for: mode)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 24, height: 24)
                    .accessibilityLabel(String(localized: "reader.repeat.title", bundle: .module))
                    .tag(mode)
            }
        }
        .pickerStyle(.segmented)
        .accessibilityValue(value)
    }

    private func icon(for mode: RepeatMode) -> Image {
        switch mode {
        case .off: Image(systemName: "arrow.forward.to.line.compact")
        case .loopAll: Image(systemName: "repeat")
        case .abLoop: Image(
                uiImage: UIImage(resource: .repeatAB)
                    .resized(to: CGSize(width: 18, height: 18)),
            )
        }
    }

    private var value: String {
        switch selection {
        case .off: String(localized: "reader.repeat.off", bundle: .module)
        case .loopAll: String(localized: "reader.repeat.loopAll", bundle: .module)
        case .abLoop: String(localized: "reader.repeat.abLoop", bundle: .module)
        }
    }
}

extension UIImage {
    func resized(to size: CGSize) -> UIImage {
        UIGraphicsImageRenderer(size: size).image { _ in
            draw(in: CGRect(origin: .zero, size: size))
        }
    }
}

#Preview {
    RepeatModePicker(selection: .constant(.abLoop))
}
