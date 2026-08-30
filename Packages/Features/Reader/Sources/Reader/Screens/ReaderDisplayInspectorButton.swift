import ReaderInteractionCore
import SwiftUI

/// The display-settings (visual inspector) button, extracted from `ReaderTopBarControls` so the editing strip can
/// mount the identical control: the same glyph, the same popover-vs-sheet split, the same destination. The reading
/// strip wraps it in the shared inspector pill; the editing strip gives it glass of its own at the row's trailing
/// end.
///
/// Bare — no glass, no shadow — because the two call sites dress it differently; see them for the pairing rules.
struct ReaderDisplayInspectorButton: View {
    @Bindable var viewModel: ReaderViewModel

    /// Whether the button anchors its own popover. False at compact width, where `ReaderRootScreen` presents the
    /// same content as a sheet instead — see `ReaderInspectorDestinations` for why the difference matters.
    let anchorsInspectorPopovers: Bool

    /// Invoked when re-reading the PDF would discard the user's work. A re-read with nothing to lose runs straight
    /// from the control and never reaches here.
    var onConfirmReReadPDF: () -> Void = {}

    var body: some View {
        Button {
            viewModel.isVisualInspectorPresented.toggle()
        } label: {
            Image(systemName: "text.page")
                .font(.system(size: 20, weight: .medium))
                .frame(width: 44, height: 44)
        }
        .tint(.primary)
        .accessibilityLabel(Text("reader.toolbar.showDisplaySettings", bundle: .module))
        .readerHintAnchor(.visualInspectorButton)
        .inspectorPopover(
            isPresented: $viewModel.isVisualInspectorPresented,
            anchored: anchorsInspectorPopovers,
        ) {
            ReaderInspectorDestinations(viewModel: viewModel, onConfirmReReadPDF: onConfirmReReadPDF)
                .displayInspector
        }
    }
}
