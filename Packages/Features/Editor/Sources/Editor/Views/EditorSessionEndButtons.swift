import EditorCore
import SwiftUI
import UtilityUI

// The two controls that end an editing session, modelled on the pair Photos puts either side of the display cutout:
// ✕ leading, which throws this session's work away, and a single trailing control that either commits it or offers
// to go back to the original.
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
/// out, and a confirmation would be noise. The dialog itself lives on `EditorTopBarView`'s stable root (like the
/// revert one), because this button is drawn in whichever tier the device has.
public struct EditorDiscardButton: View {
    @Bindable var viewModel: EditorViewModel
    /// Leaves the session. A closure, not a view-model call, because leaving routes through
    /// `ReaderEditingHost.requestExit()`, which this package cannot see.
    let onExit: () -> Void
    /// `true` in the cutout tier, where the control is drawn to the band's own proportions rather than the control
    /// tier's — see `EditorSessionBandMetrics`.
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
            label
        }
        .tint(.primary)
        .frame(minHeight: 44)
        .accessibilityLabel(Text("editor.discard.action", bundle: .module))
        .destructiveConfirmationPopover(
            isPresented: $viewModel.isConfirmingDiscard,
            message: viewModel.discardConfirmationMessage,
            actionTitle: Text("editor.discard.confirm.action", bundle: .module),
        ) {
            Task {
                await viewModel.discardSessionEdits()
                onExit()
            }
        }
    }

    /// Split out of the `Button` closure: an `if` directly inside a button label trips SwiftUI's preview
    /// instrumentation ("ambiguous use of `__designTimeSelection`"), which takes every `#Preview` in this file down
    /// with it.
    @ViewBuilder
    private var label: some View {
        if inCutoutBand {
            Image(systemName: "xmark")
                .font(EditorSessionBandMetrics.glyphFont)
                .bandPill()
                .interactiveGlassCompat()
        } else {
            Image(systemName: "xmark")
                .font(.system(size: 17, weight: .semibold))
                .frame(width: 44, height: 44)
        }
    }
}

/// The trailing control, which is three controls wearing one slot. Which one is showing is the whole status readout
/// for the session, so it is derived — never set — and changes the instant the score does:
///
/// * **nothing has ever been edited** — a checkmark on plain glass. Leaving changes nothing, so it is quiet.
/// * **the score differs from the original, but not because of this session** — revert, on red. The only thing worth
///   offering is undoing the *previous* work, and it is destructive, so it is the one coloured control in the strip.
/// * **this session has changed something** — a checkmark on yellow. Committing is now a real act with a real
///   result, and the colour says the score is not what it was when you opened it.
///
/// The session's own edits win over the revert offer deliberately: while you are mid-edit, the thing you want is to
/// keep or drop what you just did, not to be offered a rollback of everything.
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

    public var body: some View {
        Button(role: mode == .revert ? .destructive : nil) {
            if mode == .revert {
                viewModel.isConfirmingRevert = true
            } else {
                onExit()
            }
        } label: {
            label
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
        viewModel.revertConfirmationMessage(hasMusicalAnnotations: hasMusicalAnnotations)
    }

    private var accessibilityKey: LocalizedStringKey {
        switch mode {
        case .commitUnchanged, .commitEdited:
            "editor.commit.action"
        case .revert:
            viewModel.revertsToConversionOutput ? "editor.revert.action.pdf" : "editor.revert.action"
        }
    }

    /// The red and the yellow are carried BY the glass (`tintedGlassCompat`), not painted as a flat fill behind it,
    /// so a coloured state belongs to the same family of surfaces as the uncoloured one — the control changes colour,
    /// not material. It is also the control's single surface: an earlier version put a glass pill around the button
    /// and a smaller filled capsule inside it, which read as two stacked controls.
    @ViewBuilder
    private var label: some View {
        switch mode {
        case .commitUnchanged:
            checkmark
                .interactiveGlassCompat()
        case .commitEdited:
            checkmark
                .foregroundStyle(.black)
                .tintedGlassCompat(.yellow, in: .capsule)
        case .revert:
            revertLabel
        }
    }

    @ViewBuilder
    private var checkmark: some View {
        if inCutoutBand {
            Image(systemName: "checkmark")
                .font(EditorSessionBandMetrics.glyphFont)
                .bandPill()
        } else {
            Image(systemName: "checkmark")
                .font(.system(size: 17, weight: .semibold))
                .frame(width: 44, height: 44)
        }
    }

    @ViewBuilder
    private var revertLabel: some View {
        if inCutoutBand {
            Text("editor.revert.action.short", bundle: .module)
                .font(EditorSessionBandMetrics.font)
                .foregroundStyle(.white)
                .bandPill()
                .tintedGlassCompat(.red, in: .capsule)
        } else {
            Text("editor.revert.action.short", bundle: .module)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .frame(minHeight: 34)
                .tintedGlassCompat(.red, in: .capsule)
        }
    }
}

/// The band's own proportions, taken from a Photos screenshot rather than chosen: its ✕ and 元に戻す are each 26pt
/// tall and 64–66pt wide, centred in the 62pt reserved band.
///
/// The Reader owns the band itself and its horizontal inset (`ReaderTopBarLayout.cutoutTierHorizontalInset`, from the
/// same measurement). Editor cannot see that type — Features don't import each other — so these numbers live here.
/// Nothing enforces the pairing; if one moves, look at the other.
enum EditorSessionBandMetrics {
    static let height: CGFloat = 26
    static let minimumWidth: CGFloat = 64
    /// Small on purpose: a 26pt pill cannot carry body text. Photos' own label measures ~13pt.
    static let font: Font = .footnote.weight(.semibold)
    /// Glyphs sit a touch larger than the text does, or ✕ and ✓ read as specks against a word of the same weight.
    static let glyphFont: Font = .system(size: 14, weight: .semibold)
}

extension View {
    /// Shapes a label into the band's pill: fixed height, matched minimum width, capsule-clipped so whatever surface
    /// the caller puts behind it is that pill and nothing else.
    fileprivate func bandPill() -> some View {
        padding(.horizontal, 10)
            .frame(
                minWidth: EditorSessionBandMetrics.minimumWidth,
                minHeight: EditorSessionBandMetrics.height,
            )
            .frame(height: EditorSessionBandMetrics.height)
            .clipShape(.capsule)
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
