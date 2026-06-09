import Domain
import SwiftUI

/// Three-state segmented control for the global playlist-continuation setting. Shown only in playlist context.
struct PlaylistContinuationPicker: View {
    @Binding var selection: PlaylistContinuationMode

    var body: some View {
        Picker("", selection: $selection) {
            Text("reader.inspector.continuation.off", bundle: .module)
                .tag(PlaylistContinuationMode.off)
            Text("reader.inspector.continuation.playThrough", bundle: .module)
                .tag(PlaylistContinuationMode.playThrough)
            Text("reader.inspector.continuation.loopPlaylist", bundle: .module)
                .tag(PlaylistContinuationMode.loopPlaylist)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
    }
}

#if DEBUG
#Preview {
    PlaylistContinuationPicker(selection: .constant(.playThrough))
}
#endif
