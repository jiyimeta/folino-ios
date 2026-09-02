import SwiftUI

struct ImportLoadingHUD: View {
    var body: some View {
        ZStack {
            // Near-invisible tap-capture layer so the user can't reach the library underneath while the import is
            // running.
            Color.black.opacity(0.001)
                .ignoresSafeArea()
                .accessibilityHidden(true)
            VStack(spacing: 16) {
                ProgressView().controlSize(.large)
                Text("app.import.loading.label")
            }
            .padding(24)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
            .accessibilityElement(children: .combine)
        }
        .transition(.opacity)
    }
}
