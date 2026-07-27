import Foundation
import SwiftUI

/// Segmented 1…4 voice picker bound to `EditorViewModel.activeVoice` (spec §5.5). `activeVoice` is the 0-based voice
/// index; each segment shows the 1-based number. In a `Menu` the segmented style falls back to inline rows, which is
/// acceptable (spec §5.7). The picker's own label ("声部") is hidden by the segmented style but read by VoiceOver and
/// used as the section title in the menu fallback; callers that want a visible caption add one alongside.
struct EditorVoicePicker: View {
    @Bindable var viewModel: EditorViewModel

    /// Number of voices offered. MuseScore staves carry up to four voices.
    private static let voiceCount = 4

    var body: some View {
        Picker(selection: $viewModel.activeVoice) {
            ForEach(0 ..< Self.voiceCount, id: \.self) { index in
                Text(verbatim: "\(index + 1)")
                    .accessibilityLabel(Text(voiceLabel(index)))
                    .tag(index)
            }
        } label: {
            Text("editor.voice.label", bundle: .module)
        }
        .pickerStyle(.segmented)
    }

    private func voiceLabel(_ index: Int) -> String {
        String(format: String(localized: "editor.voice.n", bundle: .module), index + 1)
    }
}
