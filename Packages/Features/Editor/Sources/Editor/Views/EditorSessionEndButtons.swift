import EditorCore
import ScoreUI
import SwiftUI
import UtilityUI

// The two controls that end an editing session, modelled on the pair Photos puts either side of the display cutout:
// ✕ leading, which throws this session's work away, and a single trailing control that either commits it or offers
// to go back to the original. The drawn surfaces are ScoreUI's (`SessionDiscardLabel` / `SessionEndControlLabel`),
// shared with the Reader's annotation session so the two strips read as the same physical thing; what is decided
// HERE is what the controls do to the score.
//
// Shared, public types rather than private pieces of `EditorTopBarView` because the App mounts them in TWO separate
// places depending on the device: the Reader's own `ReaderCutoutTier` (via `ReaderRootScreen.editingCutoutTier`) on a
// device with one, or inline in `EditorTopBarView`'s own control-tier row where there isn't (the Reader owns the
// real cutout-tier layout code, not a re-declared copy).
//
// Both read `EditorViewModel` directly rather than taking every action as an escaping closure (only leaving the
// session is truly external — the Reader owns that), so the same instance can be constructed independently in the
// Reader's tree and in `EditorTopBarView`'s without either side threading extra plumbing through
// `ReaderEditingChromeContext`.

/// ✕ — throws away everything this session did and leaves.
///
/// Only asks first when there is something to throw away; on a session that changed nothing this is simply the way
/// out, and a confirmation would be noise.
public struct EditorDiscardButton: View {
    @Bindable var viewModel: EditorViewModel
    /// Leaves the session. A closure, not a view-model call, because leaving routes through
    /// `ReaderEditingHost.requestExit()`, which this package cannot see.
    let onExit: () -> Void
    /// `true` in the cutout tier, where the control is drawn to the band's own proportions rather than the control
    /// tier's — see `SessionBandMetrics`.
    let inCutoutBand: Bool

    public init(viewModel: EditorViewModel, onExit: @escaping () -> Void, inCutoutBand: Bool = false) {
        self.viewModel = viewModel
        self.onExit = onExit
        self.inCutoutBand = inCutoutBand
    }

    public var body: some View {
        Button {
            if viewModel.sessionHasEdits {
                viewModel.isConfirmingDiscard = true
            } else {
                // Still through `discardSessionEdits()`, not straight out: a session with nothing to throw away can
                // still be carrying history — edit a note, undo it, and both stacks are full at depth zero — and ✕
                // ends all retained history for the score unconditionally. It has nothing to unwind and writes
                // nothing, so there is still no confirmation to ask for.
                Task {
                    await viewModel.discardSessionEdits()
                    onExit()
                }
            }
        } label: {
            SessionDiscardLabel(inCutoutBand: inCutoutBand)
        }
        .tint(.primary)
        .frame(minHeight: 44)
        .accessibilityLabel(Text("editor.discard.action", bundle: .module))
        .destructiveConfirmationPopover(
            isPresented: $viewModel.isConfirmingDiscard,
            message: String(localized: "editor.discard.confirm.message", bundle: .module),
            actionTitle: Text("editor.discard.confirm.action", bundle: .module),
        ) {
            Task {
                await viewModel.discardSessionEdits()
                onExit()
            }
        }
    }
}

/// The trailing control, which is three controls wearing one slot — see `SessionEndControlStyle` for what each
/// state means. Which one is showing is derived from `EditorViewModel.sessionEndMode`, never set, and changes the
/// instant the score does.
public struct EditorSessionEndButton: View {
    @Bindable var viewModel: EditorViewModel
    /// Leaves the session, keeping the changes — see `EditorDiscardButton.onExit`.
    let onExit: () -> Void
    /// The Reader's answer, needed for the revert confirmation's wording: the Editor cannot see the ink, so whether
    /// handwriting is anchored to the notation is not a question it can answer for itself.
    let hasMusicalAnnotations: Bool
    let inCutoutBand: Bool

    public init(
        viewModel: EditorViewModel,
        onExit: @escaping () -> Void,
        hasMusicalAnnotations: Bool = false,
        inCutoutBand: Bool = false,
    ) {
        self.viewModel = viewModel
        self.onExit = onExit
        self.hasMusicalAnnotations = hasMusicalAnnotations
        self.inCutoutBand = inCutoutBand
    }

    private var mode: EditorSessionEndMode {
        viewModel.sessionEndMode
    }

    private var style: SessionEndControlStyle {
        switch mode {
        case .commitUnchanged: .commitUnchanged
        case .commitEdited: .commitEdited
        case .revert: .revert
        }
    }

    public var body: some View {
        Button(role: mode == .revert ? .destructive : nil) {
            if mode == .revert {
                viewModel.isConfirmingRevert = true
            } else {
                onExit()
            }
        } label: {
            SessionEndControlLabel(style: style, inCutoutBand: inCutoutBand)
        }
        .tint(.primary)
        // The drawn pill is smaller than the touch target in both tiers, deliberately: 26pt keeps it inside the
        // band's proportions, and 44pt stays tappable.
        .frame(minHeight: 44)
        .accessibilityLabel(Text(accessibilityKey, bundle: .module))
        .destructiveConfirmationPopover(
            isPresented: $viewModel.isConfirmingRevert,
            message: revertMessage,
            actionTitle: Text("editor.revert.confirm.action", bundle: .module),
        ) {
            Task { await viewModel.revertToOriginal() }
        }
    }

    /// The base wording, plus whichever caveats this particular score earns. The caveats are not decoration: a row
    /// that predates originals being kept may be restoring an already-edited state, and ink anchored to the notation
    /// can move under it. `RevertPolicy` decides which apply.
    private var revertMessage: String {
        let warnings = viewModel.revertWarnings(hasMusicalAnnotations: hasMusicalAnnotations)
        var lines = [String(localized: "editor.revert.confirm.body", bundle: .module)]
        if warnings.contains(.musicalAnnotationsMayShift) {
            lines.append(String(localized: "editor.revert.confirm.inkMayShift", bundle: .module))
        }
        if warnings.contains(.originalMayNotBeImportTime) {
            lines.append(String(localized: "editor.revert.confirm.mayNotBeImport", bundle: .module))
        }
        return lines.joined(separator: "\n\n")
    }

    private var accessibilityKey: LocalizedStringKey {
        switch mode {
        case .commitUnchanged, .commitEdited:
            "editor.commit.action"
        case .revert:
            viewModel.revertsToConversionOutput ? "editor.revert.action.pdf" : "editor.revert.action"
        }
    }
}

#if DEBUG
@MainActor
private func previewViewModel(canRevert: Bool, sessionEdits: Bool = false) -> EditorViewModel {
    let viewModel = PreviewEditorFactory.makeViewModel(armedDuration: sessionEdits ? .quarter : nil)
    if canRevert {
        // `refreshRow` is the supported way in — it re-seeds the row AND `hasCapturedOriginal` together, which is
        // the pairing the core owns.
        viewModel.refreshRow(viewModel.scoreItem.capturingOriginal(
            fileName: "preview.original.mscx", contentHash: "preview-original", provenance: .importTime,
        ))
    }
    if sessionEdits {
        viewModel.previewSeedSessionEdit()
    }
    return viewModel
}

// The shape `ReaderRootScreen.editingCutoutTier` mounts on a device with a cutout tier: ✕ leading, the session-end
// control trailing, nothing in between — the cutout's width varies by model and neither button may assume how much
// room the middle has.
//
// The frame reproduces the real band so this preview can be measured against the Photos screenshot it was matched
// to: 45pt inset each side (`ReaderTopBarLayout.cutoutTierHorizontalInset`), 62pt tall, which is an iPhone 16 Pro's
// top safe area. Photos' own controls land at x 44…110 and x 293…357 on a 402pt-wide screen.
#Preview("Cutout tier · all three states") {
    VStack(spacing: 0) {
        band(viewModel: previewViewModel(canRevert: false))
        band(viewModel: previewViewModel(canRevert: true))
        band(viewModel: previewViewModel(canRevert: true, sessionEdits: true))
    }
    .background(Color(white: 0.97))
}

@MainActor
private func band(viewModel: EditorViewModel) -> some View {
    HStack {
        EditorDiscardButton(viewModel: viewModel, onExit: {}, inCutoutBand: true)
        Spacer(minLength: 0)
        EditorSessionEndButton(viewModel: viewModel, onExit: {}, inCutoutBand: true)
    }
    .padding(.horizontal, 45)
    .frame(maxWidth: .infinity)
    .frame(height: 62)
}
#endif
