import SwiftUI

struct DrainBannerView: View {
    let message: String
    var body: some View {
        Text(message)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.regularMaterial, in: Capsule())
            .padding(.top, 12)
            .shadow(radius: 4)
            .transition(.move(edge: .top).combined(with: .opacity))
    }
}
