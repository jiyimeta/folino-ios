import SwiftUI

/// The chrome's fixed controls — voice, the pad toggle, undo / redo / 完了 — as navigation-bar items.
///
/// They used to be a floating pill row drawn in the chrome overlay's top-trailing corner. The Reader keeps its
/// navigation bar MOUNTED (but empty) for the duration of an edit session, deliberately, so the score's top inset —
/// and with it a paged score's page breaks — doesn't shift when editing starts. That left this row sitting *below* an
/// empty bar: two stacked strips of chrome over the music, the lower one re-drawing glass the bar already supplies.
///
/// A `.toolbar` attached anywhere inside the navigation container reaches that same bar, so the App-injected chrome
/// can fill the bar the Reader vacates without either feature importing the other — no new seam, and no
/// `ToolbarContent` to type-erase across the module boundary.
extension EditorChromeView {
    /// Voice + pad toggle lead, undo / redo / 完了 trail. Five items with the back button hidden for the session, so
    /// the width budget that forces the Reader's own toolbar to fold (see `ReaderToolbar.Metrics`) has room to spare
    /// here.
    @ToolbarContentBuilder
    var editingToolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) { voiceMenu }
        leadingGroupSeparator
        ToolbarItem(placement: .topBarLeading) { padToggleButton }
        ToolbarItem(placement: .topBarTrailing) {
            toolbarIconButton(system: "arrow.uturn.backward", label: "editor.chrome.undo", enabled: viewModel.canUndo) {
                viewModel.undo()
            }
        }
        ToolbarItem(placement: .topBarTrailing) {
            toolbarIconButton(system: "arrow.uturn.forward", label: "editor.chrome.redo", enabled: viewModel.canRedo) {
                viewModel.redo()
            }
        }
        ToolbarItem(placement: .topBarTrailing) {
            Button {
                onDone()
            } label: {
                Text("editor.chrome.done", bundle: .module)
                    .fontWeight(.semibold)
            }
        }
    }

    /// Breaks the shared glass container between the voice picker and the pad toggle so they read as two separate
    /// pills — they are unrelated controls (which voice you write into vs. whether the keyboard is up), and grouped
    /// they look like one segmented control. Mirrors `ReaderToolbar.groupSeparator`; iOS 18 has no grouping to break,
    /// so it contributes nothing there.
    @ToolbarContentBuilder
    private var leadingGroupSeparator: some ToolbarContent {
        if #available(iOS 26, *) {
            ToolbarSpacer(.fixed, placement: .topBarLeading)
        }
    }

    /// Shows and hides the pad. Editing is two different activities sharing one screen: putting notes IN, which needs
    /// the whole keyboard, and going over what's there — changing a pitch, adding an accidental — which needs the
    /// callout beside the note and nothing else. The pad is a big bite out of a phone screen to leave standing during
    /// the second, so it comes and goes; the callout stays either way.
    ///
    /// Inverted rather than swapped, exactly like the Reader's annotation toggle: same glyph in both states, active =
    /// white on a black disc. Two icons for one control reads as two different buttons. Black rather than the accent
    /// tint, deliberately — this is a mode indicator, not a call to action, and the glyph carries the same ink weight
    /// as the score it sits over. The glyph keeps a FIXED frame in both states so the disc can't change the item's
    /// width — a toolbar item that grows when it is toggled on is what makes iOS 26 start folding the row into an
    /// overflow menu of its own.
    private var padToggleButton: some View {
        Button {
            withAnimation(.snappy(duration: 0.28)) { isPadVisible.toggle() }
        } label: {
            Image("custom.music.note.badge.plus", bundle: .module)
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(isPadVisible ? Color.white : Color.primary)
                // The badge hangs off the note's right, so the symbol's ink sits right of its own box's centre and the
                // glyph looked shunted over inside the round button. Nudged back by a tenth of its size.
                .offset(x: -1.5)
                .frame(width: 30, height: 30)
                .background {
                    if isPadVisible {
                        Circle().fill(Color.black)
                    }
                }
        }
        .tint(.primary)
        .accessibilityLabel(Text(
            isPadVisible ? "editor.chrome.hidePad" : "editor.chrome.showPad", bundle: .module,
        ))
        // Relayed to the Reader (via the App) so its note-input coach mark can point here. Its PLACE in this row, not
        // a frame: a bar item cannot measure itself (it reports its own bounds centred on the origin), so the Reader
        // matches the ordinal against the bar's rendered items. Second, because the voice picker leads — the fixed
        // spacer between them is not an item.
        .onAppear { onNoteInputBarOrderChange(1) }
        .onDisappear { onNoteInputBarOrderChange(nil) }
    }

    /// The voice picker used to hide behind the callout's `⋯`; as its own item it stays reachable with nothing
    /// selected, which is when you most often need to switch the voice you're about to input into.
    private var voiceMenu: some View {
        Menu {
            EditorVoicePicker(viewModel: viewModel)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "person.2")
                Text(verbatim: "\(viewModel.activeVoice + 1)")
                    .fontWeight(.semibold)
            }
        }
        .accessibilityLabel(Text("editor.voice.label", bundle: .module))
    }

    /// Built from a `Label` left unstyled apart from `.iconOnly`: the bar renders the glyph alone, and the same button
    /// keeps its title if it ever ends up in a menu row.
    private func toolbarIconButton(
        system: String,
        label: LocalizedStringKey,
        enabled: Bool,
        action: @escaping () -> Void,
    ) -> some View {
        Button(action: action) {
            Label {
                Text(label, bundle: .module)
            } icon: {
                Image(systemName: system)
            }
            .labelStyle(.iconOnly)
        }
        .disabled(!enabled)
        .accessibilityLabel(Text(label, bundle: .module))
    }
}
