#if DEBUG
import SwiftUI

extension View {
    func debuggable() -> some View {
        modifier(DebuggableViewModifier())
    }
}

private struct DebuggableViewModifier: ViewModifier {
    @State private var isDebugViewPresented = false

    func body(content: Content) -> some View {
        content
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        isDebugViewPresented = true
                    } label: {
                        Image(systemName: "ladybug.fill")
                    }
                }
            }
            .sheet(isPresented: $isDebugViewPresented) {
                DebugView()
            }
    }
}

private struct DebugView: View {
    var body: some View {
        Form {
            Button("fatalError") {
                fatalError("Crashed manually.")
            }
        }
    }
}
#endif
