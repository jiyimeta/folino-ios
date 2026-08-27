import Domain
import SwiftUI
import UtilityUI

/// The editing session's control tier (`ReaderRootScreen.editingTopBar`) — voice picker, undo, redo, and, where
/// there is no cutout tier, 完了 and revert too.
///
/// These are plain views, not `ToolbarContent`: the Reader hides the navigation bar and draws its own strip, so
/// there is no bar for a `.toolbar` to fill. The pad has no show / hide control here either — it is dismissed and
/// recalled in place, PiP-style (see `EditorChromeView`).
///
/// **The cutout tier is NOT drawn here.** Where one exists, 完了 and revert are mounted by the Reader's own
/// `ReaderCutoutTier` instead (`ReaderRootScreen.editingCutoutTier`, using the shared `EditorDoneButton` /
/// `EditorRevertButton` views). An earlier draft re-declared `ReaderCutoutTier`'s
/// `offset`/`ignoresSafeArea` shape locally (this package cannot import `Reader` to reuse the type itself), which
/// left two independently-positioned mechanisms both claiming the same band, exactly what the design spec warns
/// against. Reusing the Reader's real layout code makes that structurally impossible instead of merely unlikely.
///
/// **Control tier**: the voice picker leads, undo and redo trail. Where there is no cutout tier, 完了 and revert
/// join this row and the whole thing folds with `ViewThatFits`, the same ladder shape the Reader's own row uses
/// (`Collapse`, `Spacer(minLength: 0)`, fixed icon frames).
public struct EditorTopBarView: View {
    @Bindable var viewModel: EditorViewModel
    let hasMusicalAnnotations: Bool
    /// Whether this device's top safe-area inset is wide enough to host a control — see
    /// `ReaderTopBarLayout.hasCutoutTier(topSafeAreaInset:)`, computed by the App and handed down as a plain value
    /// (this package cannot import `Reader` to read `ReaderTopBarLayout` itself).
    let hasCutoutTier: Bool
    let onDone: () -> Void

    /// How much the control tier gives up as width tightens, when 完了 and revert are IN it (no cutout tier).
    ///
    /// Only two rungs, not three: a `.revert`-only middle rung (revert alone folded into `⋯`, 完了 still a
    /// standalone text button) measures IDENTICAL to `.expanded` whenever revert is showing — swapping one 44×44
    /// icon (`revertButton`) for another (the `⋯` menu) saves nothing, so `ViewThatFits` could never actually pick
    /// it. `doneButton`'s `minWidth: 60` is what makes `.folded` unconditionally narrower than
    /// `.expanded` — see the comment there.
    enum Collapse {
        case expanded
        case folded
    }

    public init(
        viewModel: EditorViewModel,
        hasMusicalAnnotations: Bool,
        hasCutoutTier: Bool,
        onDone: @escaping () -> Void,
    ) {
        self.viewModel = viewModel
        self.hasMusicalAnnotations = hasMusicalAnnotations
        self.hasCutoutTier = hasCutoutTier
        self.onDone = onDone
    }

    public var body: some View {
        // The shadow matches `ReaderTopBarControls`' so the reading and editing strips read as the same physical
        // surface.
        revertFailureAlert(on: controlTierRow)
            .shadow(color: .gray.opacity(0.3), radius: 10, y: 5)
    }

    // MARK: - Control tier

    @ViewBuilder
    private var controlTierRow: some View {
        if hasCutoutTier {
            // ✕ and the session-end control live in the cutout tier; three controls never risk running out of room,
            // so no fold.
            HStack(spacing: 12) {
                undoRedoGroup
                Spacer(minLength: 0)
                voiceButton
            }
        } else if viewModel.sessionEndMode == .revert {
            // `Spacer(minLength: 0)` inside `row(collapse:)` is what lets `ViewThatFits` fold at all — a greedy
            // spacer would make every candidate report that it fits, and the fold would silently never trigger.
            ViewThatFits(in: .horizontal) {
                row(collapse: .expanded)
                row(collapse: .folded)
            }
        } else {
            // Only `.revert` is wide enough for the fold to buy anything: in both checkmark states the session-end
            // control is a 44pt glyph and `⋯` is another one, so `.folded` would measure the same as `.expanded` and
            // `ViewThatFits` could never select it. A rung that cannot be selected is not a fold level.
            row(collapse: .expanded)
        }
    }

    /// One candidate row for `ViewThatFits`, used only where there is no cutout tier — so this row carries ✕ and the
    /// session-end control itself, which on a cutout device live in the band instead.
    private func row(collapse: Collapse) -> some View {
        HStack(spacing: 12) {
            EditorDiscardButton(viewModel: viewModel, onExit: onDone)
                .interactiveGlassCompat()
            undoRedoGroup
            Spacer(minLength: 0)
            voiceButton
            switch collapse {
            case .expanded:
                endGroup
            case .folded:
                overflowMenu
                    .interactiveGlassCompat()
            }
        }
    }

    /// Undo + redo, sharing one glass pill, leading — the pairing is the point: they are one control's two
    /// directions, and Photos puts the same pair in the same place.
    private var undoRedoGroup: some View {
        HStack(spacing: 0) {
            undoButton
            redoButton
        }
        .interactiveGlassCompat()
    }

    /// Bare glyphs need something behind them to stay legible over arbitrary score content, so
    /// the voice picker gets glass of its own.
    private var voiceButton: some View {
        voiceMenu
            .interactiveGlassCompat()
    }

    /// The session-end control — checkmark or revert, depending on `EditorViewModel.sessionEndMode`. One control,
    /// three states; it carries its own surface and its own confirmation.
    private var endGroup: some View {
        EditorSessionEndButton(
            viewModel: viewModel,
            onExit: onDone,
            hasMusicalAnnotations: hasMusicalAnnotations,
        )
    }

    /// Narrow-width stand-in for revert (if available) and 完了 once they've folded together.
    private var overflowMenu: some View {
        Menu {
            if viewModel.canRevertToOriginal {
                revertMenuRow
            }
            doneMenuRow
        } label: {
            topBarIcon("ellipsis")
        }
        .tint(.primary)
        .accessibilityLabel(L10n.Common.more)
    }

    // MARK: - Voice

    private var voiceMenu: some View {
        Menu {
            EditorVoicePicker(viewModel: viewModel)
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "person.2")
                Text(verbatim: "\(viewModel.activeVoice + 1)")
                    .fontWeight(.semibold)
            }
            // Padded rather than squeezed into a bare 44pt square: the icon and the numeral together are almost
            // exactly 44pt wide, so a minimum-width frame put the glass hard against both of them.
            .padding(.horizontal, 12)
            .frame(minHeight: 44)
        }
        .tint(.primary)
        .accessibilityLabel(Text("editor.voice.label", bundle: .module))
    }

    // MARK: - Undo / redo

    private var undoButton: some View {
        topBarButton(system: "arrow.uturn.backward", label: "editor.chrome.undo", enabled: viewModel.canUndo) {
            viewModel.undo()
        }
    }

    private var redoButton: some View {
        topBarButton(system: "arrow.uturn.forward", label: "editor.chrome.redo", enabled: viewModel.canRedo) {
            viewModel.redo()
        }
    }

    private func topBarButton(
        system: String, label: LocalizedStringKey, enabled: Bool, action: @escaping () -> Void,
    ) -> some View {
        Button(action: action) {
            topBarIcon(system)
        }
        .tint(.primary)
        .disabled(!enabled)
        .accessibilityLabel(Text(label, bundle: .module))
    }

    /// The 44×44 tappable glyph shared by the strip's icon buttons — every button keeps this fixed frame so what a
    /// `ViewThatFits` candidate needs is a function of how many buttons it has, not of their content.
    private func topBarIcon(_ systemImage: String) -> some View {
        Image(systemName: systemImage)
            .font(.system(size: 20, weight: .medium))
            .frame(width: 44, height: 44)
    }

    // MARK: - Session end

    private var doneMenuRow: some View {
        Button(action: onDone) {
            Label {
                Text("editor.chrome.done", bundle: .module)
            } icon: {
                Image(systemName: "checkmark")
            }
        }
    }

    private var revertMenuRow: some View {
        Button(role: .destructive) {
            viewModel.isConfirmingRevert = true
        } label: {
            Label {
                // A PDF-origin sidecar is the conversion's output, not the file the user imported — the imported
                // PDF is a separate original sitting in the same sheet, so this must not call the sidecar "the
                // original" a second time (design spec, "Two originals must never be called the same thing").
                Text(
                    viewModel.revertsToConversionOutput ? "editor.revert.action.pdf" : "editor.revert.action",
                    bundle: .module,
                )
            } icon: {
                Image(systemName: "arrow.counterclockwise")
            }
        }
    }

    /// A revert that fails silently is worse than no confirmation at all: the popover closes either way, so
    /// without this the user has no way to tell "reverted" apart from "the store threw and nothing happened".
    /// `revertError` is cleared on dismiss so a later successful revert can't re-show a stale alert.
    ///
    /// This one stays on the row rather than moving to the button with the confirmations: by the time it has
    /// something to say the revert has already ended the session, so the control that raised it is gone.
    private func revertFailureAlert(on content: some View) -> some View {
        content
            .alert(
                Text("editor.revert.failed", bundle: .module),
                isPresented: isRevertErrorPresented,
            ) {
                Button {
                    viewModel.revertError = nil
                } label: {
                    Text("editor.revert.failed.dismiss", bundle: .module)
                }
            } message: {
                Text(viewModel.revertError ?? "")
            }
    }

    private var isRevertErrorPresented: Binding<Bool> {
        Binding(
            get: { viewModel.revertError != nil },
            set: { isPresented in
                if !isPresented {
                    viewModel.revertError = nil
                }
            },
        )
    }
}
