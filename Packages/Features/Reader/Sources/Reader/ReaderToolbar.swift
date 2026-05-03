import Domain
import SwiftUI

/// Trailing toolbar contents and the optional bottom page indicator for
/// the Reader. Hosted from `ReaderView`'s `.toolbar { … }` modifier and
/// hidden via `isChromeVisible`.
struct ReaderToolbar: ToolbarContent {
    @Bindable var viewModel: ReaderViewModel
    @Binding var layoutMode: ReaderLayoutMode

    var body: some ToolbarContent {
        #if os(iOS)
            ToolbarItemGroup(placement: .topBarTrailing) {
                Picker("Layout", selection: $layoutMode) {
                    Image(systemName: "list.bullet").tag(ReaderLayoutMode.vertical)
                    Image(systemName: "book.closed").tag(ReaderLayoutMode.page)
                }
                .pickerStyle(.segmented)

                Button {
                    Task { await viewModel.decrementStaffSize() }
                } label: {
                    Image(systemName: "minus.magnifyingglass")
                }
                .disabled(viewModel.preferences.staffSize <= ReaderPreferences.minStaffSize)

                Button {
                    Task { await viewModel.incrementStaffSize() }
                } label: {
                    Image(systemName: "plus.magnifyingglass")
                }
                .disabled(viewModel.preferences.staffSize >= ReaderPreferences.maxStaffSize)

                Button {
                    viewModel.isInspectorPresented.toggle()
                } label: {
                    Image(systemName: "sidebar.right")
                }
                .accessibilityLabel("Show staves panel")
            }
        #else
            ToolbarItemGroup(placement: .automatic) {
                Picker("Layout", selection: $layoutMode) {
                    Image(systemName: "list.bullet").tag(ReaderLayoutMode.vertical)
                    Image(systemName: "book.closed").tag(ReaderLayoutMode.page)
                }
                .pickerStyle(.segmented)

                Button {
                    Task { await viewModel.decrementStaffSize() }
                } label: {
                    Image(systemName: "minus.magnifyingglass")
                }
                .disabled(viewModel.preferences.staffSize <= ReaderPreferences.minStaffSize)

                Button {
                    Task { await viewModel.incrementStaffSize() }
                } label: {
                    Image(systemName: "plus.magnifyingglass")
                }
                .disabled(viewModel.preferences.staffSize >= ReaderPreferences.maxStaffSize)

                Button {
                    viewModel.isInspectorPresented.toggle()
                } label: {
                    Image(systemName: "sidebar.right")
                }
                .accessibilityLabel("Show staves panel")
            }
        #endif
    }
}

/// Bottom page indicator + reset-zoom pill. Lives outside the toolbar so
/// it can sit on top of the score content rather than in the navigation
/// bar.
struct ReaderBottomOverlay: View {
    @Bindable var viewModel: ReaderViewModel
    let layoutMode: ReaderLayoutMode
    let pageIndex: Int
    let totalPages: Int

    var body: some View {
        HStack {
            if viewModel.viewportZoom > 1.0 {
                Button {
                    viewModel.resetZoom()
                } label: {
                    Label("Reset zoom", systemImage: "arrow.up.left.and.down.right.magnifyingglass")
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .background(.ultraThinMaterial, in: Capsule())
                }
            }
            Spacer()
            if layoutMode == .page, totalPages > 0 {
                Text("\(pageIndex + 1) / \(totalPages)")
                    .font(.footnote.monospacedDigit())
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    .background(.ultraThinMaterial, in: Capsule())
            }
        }
        .padding()
        .opacity(viewModel.isChromeVisible ? 1 : 0)
        .animation(.easeInOut(duration: 0.2), value: viewModel.isChromeVisible)
    }
}
