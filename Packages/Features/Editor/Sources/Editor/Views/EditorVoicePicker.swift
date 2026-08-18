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
                // The full "Voice 1" wording, not a bare digit: a menu row has the width for it, and a column of
                // lone numerals says nothing about what is being chosen.
                Text(voiceLabel(index))
                    .tag(index)
            }
        } label: {
            Text("editor.voice.label", bundle: .module)
        }
        // Inline inside the enclosing `Menu`, which is what makes this the system's own menu: one row per voice with
        // a checkmark against the current one. It used to be `.segmented`, i.e. a segmented control transplanted
        // into a menu — a shape iOS uses nowhere else, with four bare digits as its segments.
        .pickerStyle(.inline)
    }

    private func voiceLabel(_ index: Int) -> String {
        String(format: String(localized: "editor.voice.n", bundle: .module), index + 1)
    }
}
