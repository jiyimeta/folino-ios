import SwiftUI

struct AppShellView: View {
    let bootstrap: AppBootstrap

    var body: some View {
        Group {
            if bootstrap.isReady {
                ContentView()
            } else {
                ProgressView()
            }
        }
    }
}

private struct ContentView: View {
    var body: some View {
        VStack(spacing: 16) {
            Text("Folino")
                .font(.largeTitle.weight(.semibold))
            Text("Score viewer scaffold")
                .foregroundStyle(.secondary)
        }
        .padding()
    }
}
