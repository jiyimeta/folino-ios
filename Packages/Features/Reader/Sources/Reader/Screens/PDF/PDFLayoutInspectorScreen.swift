import Domain
import SwiftUI

/// The PDF reader's only inspector: a page/vertical mode toggle plus a one-line note explaining that display
/// adjustment and playback are unavailable for PDFs. Mirrors the score Visual inspector's layout row, restricted to the
/// two PDF-allowed modes.
struct PDFLayoutInspectorScreen: View {
    /// The PDF an item was read from. Present for every item that reaches this screen — the original pages are what it
    /// is showing — so the section that switches back to the notation and re-parses belongs here just as much as it
    /// does in the score inspector.
    var pdfOrigin: PDFOriginControls?

    @AppStorage(ReaderGlobalSettingsKey.layoutMode)
    private var layoutModeRaw: String = ReaderLayoutMode.page.rawValue

    @AppStorage(ReaderGlobalSettingsKey.pageTurnButtonsVisible)
    private var pageTurnButtonsVisible = true

    /// For PDFs every non-`vertical` selection resolves to page (mirrors `ReaderRootScreen.pdfLayoutMode`), so the
    /// tap-zone toggle shows whenever the layout is not vertical.
    private var isPageLayout: Bool {
        (ReaderLayoutMode(rawValue: layoutModeRaw) ?? .page) != .vertical
    }

    var body: some View {
        List {
            if let pdfOrigin {
                PDFOriginSection(controls: pdfOrigin)
            }
            Section {
                HStack {
                    Text("reader.preferences.layoutDirection", bundle: .module)
                    Spacer()
                    // Same order as the score inspector (vertical, then page) minus horizontal, which a fixed-layout
                    // page has no equivalent for — so a user switching between a score and a PDF finds the modes in
                    // the place they already learned.
                    Picker(selection: $layoutModeRaw) {
                        Image(systemName: "arrow.up.and.down.text.horizontal")
                            .tag(ReaderLayoutMode.vertical.rawValue)
                        Image(systemName: "book.pages").tag(ReaderLayoutMode.page.rawValue)
                    } label: {
                        Text("reader.preferences.layoutDirection", bundle: .module)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 96)
                    .fixedSize()
                }
            } footer: {
                Text("reader.pdf.settingsNote", bundle: .module)
            }

            if isPageLayout {
                Section {
                    Toggle(isOn: $pageTurnButtonsVisible) {
                        Text("reader.inspector.showPageTurnButtons", bundle: .module)
                    }
                }
            }
        }
    }
}

#if DEBUG
#Preview {
    PDFLayoutInspectorScreen()
}
#endif
