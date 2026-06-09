import Domain
import SwiftUI

/// Three-state menu picker for the global playlist-continuation setting. Shown only in playlist context.
struct PlaylistContinuationPicker: View {
    @Binding var selection: PlaylistContinuationMode

    var body: some View {
        Menu {
            Picker("", selection: $selection) {
                ForEach(PlaylistContinuationMode.allCases, id: \.self) { mode in
                    Label {
                        Text(titleKey(for: mode), bundle: .module)
                    } icon: {
                        icon(for: mode)
                    }
                    .tag(mode)
                }
            }
            .labelsHidden()
        } label: {
            // Self-built label so the selected value truncates to one line (a `.menu` Picker wraps its inline value).
            InspectorMenuValueLabel {
                icon(for: selection)
            } title: {
                Text(titleKey(for: selection), bundle: .module)
            }
        }
    }

    private func titleKey(for mode: PlaylistContinuationMode) -> LocalizedStringKey {
        switch mode {
        case .off: "reader.inspector.continuation.off"
        case .playThrough: "reader.inspector.continuation.playThrough"
        case .loopPlaylist: "reader.inspector.continuation.loopPlaylist"
        }
    }

    @ViewBuilder
    private func icon(for mode: PlaylistContinuationMode) -> some View {
        switch mode {
        case .off: Image(systemName: "pause")
        case .playThrough: Image(systemName: "forward.end")
        case .loopPlaylist: Image(systemName: "repeat")
        }
    }
}

#if DEBUG
#Preview {
    PlaylistContinuationPicker(selection: .constant(.loopPlaylist))
}
#endif
