import Domain
import SwiftUI

struct RepeatModeButton: View {
    let mode: RepeatMode
    let action: () async -> Void

    var body: some View {
        Button {
            Task { await action() }
        } label: {
            Image(systemName: symbol)
                .resizable()
                .scaledToFit()
                .foregroundStyle(tint)
                .frame(width: 24, height: 24)
                .padding(.horizontal, 4)
                .symbolVariant(mode == .off ? .none : .fill)
                .accessibilityLabel(label)
        }
        .accessibilityValue(value)
    }

    private var symbol: String {
        switch mode {
        case .off, .loopAll: "repeat"
        case .abLoop: "repeat.1"
        }
    }

    private var tint: Color {
        mode == .off ? .secondary : .accentColor
    }

    private var label: String {
        String(localized: "Repeat")
    }

    private var value: String {
        switch mode {
        case .off: String(localized: "Off")
        case .loopAll: String(localized: "Loop all")
        case .abLoop: String(localized: "A–B section")
        }
    }
}

#Preview {
    VStack(spacing: 16) {
        RepeatModeButton(mode: .off) {}
        RepeatModeButton(mode: .loopAll) {}
        RepeatModeButton(mode: .abLoop) {}
    }
    .padding()
}
