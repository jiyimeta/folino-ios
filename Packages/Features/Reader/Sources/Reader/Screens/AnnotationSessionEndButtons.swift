import ReaderAnnotationCore
import ScoreUI
import SwiftUI
import UtilityUI

// The two controls that end an annotation session — the same pair, in the same two spots, as the note-editing
// session's (`EditorDiscardButton` / `EditorSessionEndButton`): ✕ leading, which puts the ink back the way it was,
// and a single trailing control that either keeps the session's ink or, on an untouched score that has ink, offers
// to delete all of it. The drawn surfaces are ScoreUI's, shared with the Editor, so the two strips read as one.
//
// Like the Editor's pair, each is mounted in one of TWO places depending on the device — the Reader's own
// `ReaderCutoutTier` where there is one, or inline in the strip's control tier where there isn't — so both read
// `ReaderViewModel` directly and keep their confirmation state on it (`isConfirmingAnnotationDiscard` /
// `isConfirmingAnnotationClear`), where it survives the control being re-mounted in the other tier.

/// ✕ — leaves annotation mode with the ink as it was when the session began.
///
/// Only asks first when there is something to throw away; on a session that changed nothing this is simply the way
/// out, and a confirmation would be noise.
struct AnnotationDiscardButton: View {
    @Bindable var viewModel: ReaderViewModel
    /// `true` in the cutout tier, where the control is drawn to the band's own proportions rather than the control
    /// tier's — see `SessionBandMetrics`.
    var inCutoutBand = false

    var body: some View {
        Button {
            if viewModel.annotationCanvasSession.hasChanges {
                viewModel.isConfirmingAnnotationDiscard = true
            } else {
                viewModel.discardAnnotationSession()
            }
        } label: {
            SessionDiscardLabel(inCutoutBand: inCutoutBand)
        }
        .tint(.primary)
        .frame(minHeight: 44)
        .accessibilityLabel(Text("reader.annotation.discard.action", bundle: .module))
        .destructiveConfirmationPopover(
            isPresented: $viewModel.isConfirmingAnnotationDiscard,
            message: String(localized: "reader.annotation.discard.confirm.message", bundle: .module),
            actionTitle: Text("reader.annotation.discard.confirm.action", bundle: .module),
        ) {
            viewModel.discardAnnotationSession()
        }
    }
}

/// The trailing control — see `AnnotationSessionEndMode` for the three states and `SessionEndControlStyle` for
/// how each is drawn. Derived from the view model, never set, and changes the instant the ink does.
struct AnnotationSessionEndButton: View {
    @Bindable var viewModel: ReaderViewModel
    var inCutoutBand = false

    private var mode: AnnotationSessionEndMode {
        viewModel.annotationSessionEndMode
    }

    private var style: SessionEndControlStyle {
        switch mode {
        case .commitUnchanged: .commitUnchanged
        case .commitEdited: .commitEdited
        case .clearAll: .revert
        }
    }

    var body: some View {
        Button(role: mode == .clearAll ? .destructive : nil) {
            if mode == .clearAll {
                viewModel.isConfirmingAnnotationClear = true
            } else {
                viewModel.finishAnnotationSession()
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
            isPresented: $viewModel.isConfirmingAnnotationClear,
            message: String(localized: "reader.annotation.clear.confirm.body", bundle: .module),
            actionTitle: Text("reader.annotation.clear.action", bundle: .module),
        ) {
            viewModel.clearAllAnnotations()
        }
    }

    private var accessibilityKey: LocalizedStringKey {
        switch mode {
        case .commitUnchanged, .commitEdited:
            "reader.annotation.done.action"
        case .clearAll:
            "reader.annotation.clear.action"
        }
    }
}
