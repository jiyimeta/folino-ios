import Domain
import SwiftUI

/// One Mac window: the library in the sidebar, the score in the detail column. Every window comes from the same
/// `WindowGroup`, which is what gives macOS's automatic window tabbing (⌘T, tab drag-out, Merge All Windows) for
/// free — see the design spec §3.3 for why a separate library `Window` would forfeit that.
struct MacShellView: View {
    let bootstrap: AppBootstrap
    @Binding var scoreID: ScoreItem.ID?
    @Binding var columnVisibility: NavigationSplitViewVisibility

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            sidebar
                .navigationSplitViewColumnWidth(min: 260, ideal: 320)
        } detail: {
            detail
        }
        .frame(minWidth: 900, minHeight: 600)
    }

    private var sidebar: some View {
        // Task 6 replaces this with LibraryRootScreen.
        Text(verbatim: "library")
    }

    @ViewBuilder
    private var detail: some View {
        if scoreID == nil {
            ContentUnavailableView {
                Label {
                    Text("app.detail.empty.title")
                } icon: {
                    Image(systemName: "music.note")
                }
            }
        } else {
            // Task 8 replaces this with MacReaderRootScreen.
            Text(verbatim: "score")
        }
    }
}
