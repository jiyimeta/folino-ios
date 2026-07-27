import SwiftUI
import UtilityUI

/// The chrome's header row — the fixed controls that stay put wherever the pad and callout go.
extension EditorChromeView {
    /// A standalone voice pill, the pad toggle, then the undo / redo / 完了 cluster. The voice picker used to hide
    /// behind the callout's `⋯`; as its own pill it stays reachable with nothing selected, which is when you most
    /// often need to switch the voice you're about to input into.
    var topCluster: some View {
        HStack(spacing: 8) {
            voicePill
            padTogglePill
            actionCluster
        }
        .padding(.horizontal)
        .padding(.top, 4)
    }

    /// Shows and hides the pad. Editing is two different activities sharing one screen: putting notes IN, which needs
    /// the whole keyboard, and going over what's there — changing a pitch, adding an accidental — which needs the
    /// callout beside the note and nothing else. The pad is a big bite out of a phone screen to leave standing during
    /// the second, so it comes and goes; the callout stays either way.
    ///
    /// Inverted rather than swapped, exactly like the Reader's annotation toggle: same glyph in both states, active =
    /// white on a black disc. Two icons for one control reads as two different buttons.
    private var padTogglePill: some View {
        Button {
            withAnimation(.snappy(duration: 0.28)) { isPadVisible.toggle() }
        } label: {
            Image("custom.music.note.badge.plus", bundle: .module)
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(isPadVisible ? Color.white : Color.primary)
                // The badge hangs off the note's right, so the symbol's ink sits right of its own box's centre and
                // the glyph looked shunted over inside the round button. Nudged back by a tenth of its size.
                .offset(x: -2)
                .frame(width: 44, height: 44)
                .background {
                    if isPadVisible {
                        Circle().fill(.black).padding(2)
                    }
                }
        }
        .tint(.primary)
        .interactiveGlassCompat()
        .shadow(color: .gray.opacity(0.3), radius: 10, y: 5)
        .accessibilityLabel(Text(
            isPadVisible ? "editor.chrome.hidePad" : "editor.chrome.showPad", bundle: .module,
        ))
    }

    private var voicePill: some View {
        Menu {
            EditorVoicePicker(viewModel: viewModel)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "person.2")
                    .font(.system(size: 15, weight: .medium))
                Text(verbatim: "\(viewModel.activeVoice + 1)")
                    .fontWeight(.semibold)
            }
            .padding(.horizontal, 12)
            .frame(minHeight: 44)
        }
        .tint(.primary)
        .interactiveGlassCompat()
        .shadow(color: .gray.opacity(0.3), radius: 10, y: 5)
        .accessibilityLabel(Text("editor.voice.label", bundle: .module))
    }

    private var actionCluster: some View {
        HStack(spacing: 0) {
            clusterIconButton(system: "arrow.uturn.backward", label: "editor.chrome.undo", enabled: viewModel.canUndo) {
                viewModel.undo()
            }
            clusterIconButton(system: "arrow.uturn.forward", label: "editor.chrome.redo", enabled: viewModel.canRedo) {
                viewModel.redo()
            }
            Button {
                onDone()
            } label: {
                Text("editor.chrome.done", bundle: .module)
                    .fontWeight(.semibold)
                    .padding(.horizontal, 10)
                    .frame(minHeight: 44)
            }
            .tint(.primary)
        }
        .interactiveGlassCompat()
        .shadow(color: .gray.opacity(0.3), radius: 10, y: 5)
    }

    private func clusterIconButton(
        system: String,
        label: LocalizedStringKey,
        enabled: Bool,
        action: @escaping () -> Void,
    ) -> some View {
        Button(action: action) {
            Image(systemName: system)
                .font(.system(size: 20, weight: .medium))
                .frame(width: 44, height: 44)
        }
        .tint(.primary)
        .disabled(!enabled)
        .accessibilityLabel(Text(label, bundle: .module))
    }
}
