import Domain
import SwiftUI

struct RepeatModeButton: View {
    let mode: RepeatMode
    let action: () async -> Void

    var body: some View {
        Button {
            Task { await action() }
        } label: {
            icon
                .resizable()
                .scaledToFit()
                .foregroundStyle(tint)
                .frame(width: 24, height: 24)
                .padding(.horizontal, 4)
                .accessibilityLabel(label)
        }
        .accessibilityValue(value)
    }

    private var icon: Image {
        switch mode {
        case .off, .loopAll: Image(systemName: "repeat")
        case .abLoop: Image("repeat_a_b", bundle: .module)
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
