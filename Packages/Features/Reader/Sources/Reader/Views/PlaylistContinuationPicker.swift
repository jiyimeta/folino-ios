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
        // No `.fixedSize()`: it pins the segmented control's tall intrinsic height, which the enclosing `List` reserves
        // as the row's cell height (a large vertical gap around the control on device). Matching `RepeatModePicker`, we
        // let the control fill the row width and clamp its height so the row stays as compact as the slider rows.
        .frame(height: 24)
    }
}

#if DEBUG
#Preview {
    PlaylistContinuationPicker(selection: .constant(.playThrough))
}
#endif
