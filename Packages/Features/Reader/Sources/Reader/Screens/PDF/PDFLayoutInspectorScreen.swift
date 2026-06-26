import Domain
import SwiftUI

/// The PDF reader's only inspector: a page/vertical mode toggle plus a one-line note explaining that display
/// adjustment and playback are unavailable for PDFs. Mirrors the score Visual inspector's layout row, restricted to the
/// two PDF-allowed modes.
struct PDFLayoutInspectorScreen: View {
    @AppStorage(ReaderGlobalSettingsKey.layoutMode)
    private var layoutModeRaw: String = ReaderLayoutMode.page.rawValue

    var body: some View {
        List {
            Section {
                HStack {
                    Text("reader.preferences.layoutDirection", bundle: .module)
                    Spacer()
                    Picker(selection: $layoutModeRaw) {
                        Image(systemName: "book.pages").tag(ReaderLayoutMode.page.rawValue)
                        Image(systemName: "arrow.up.and.down.text.horizontal")
                            .tag(ReaderLayoutMode.vertical.rawValue)
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
        }
    }
}

#if DEBUG
#Preview {
    PDFLayoutInspectorScreen()
}
#endif
