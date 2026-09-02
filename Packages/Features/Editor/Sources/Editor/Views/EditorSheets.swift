import SwiftUI

extension View {
    /// Installs every sheet the Editor can raise — instruments, key signature, time signature, rehearsal mark, add
    /// measures, drum layout — driven by the view model's presentation flags.
    ///
    /// Public so a host that has no `EditorTopBarView` (the Mac, whose entry points are menu commands) can present
    /// the same sheets from the same flags. Apply it ONCE, to a view that lives as long as the editor does: a sheet
    /// attached to a control that can disappear goes with it, which is the rule every iOS presentation here already
    /// follows (`EditorTopBarView+MeasureMenu.measureMenuSheets`).
    public func editorSheets(viewModel: EditorViewModel) -> some View {
        modifier(EditorSheetsModifier(viewModel: viewModel))
    }
}

private struct EditorSheetsModifier: ViewModifier {
    @Bindable var viewModel: EditorViewModel

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: $viewModel.isInstrumentsSheetPresented) {
                EditorInstrumentsSheet(viewModel: viewModel)
            }
            .sheet(isPresented: $viewModel.isKeySignatureSheetPresented) {
                EditorKeySignatureSheet(viewModel: viewModel)
            }
            .sheet(isPresented: $viewModel.isTimeSignatureSheetPresented) {
                EditorTimeSignatureSheet(viewModel: viewModel)
            }
            .sheet(isPresented: $viewModel.isRehearsalMarkSheetPresented) {
                EditorRehearsalMarkSheet(viewModel: viewModel)
            }
            .sheet(isPresented: $viewModel.isAddMeasuresSheetPresented) {
                EditorAddMeasuresSheet(viewModel: viewModel)
            }
            .sheet(isPresented: $viewModel.isDrumLayoutSheetPresented) {
                EditorDrumLayoutSheet(initial: viewModel.drumPadLayout) { layout in
                    viewModel.setDrumPadLayout(layout)
                    DrumPadLayoutStore.save(layout)
                }
            }
    }
}
