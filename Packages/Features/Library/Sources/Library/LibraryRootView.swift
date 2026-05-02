import Domain
import SwiftUI

/// Public entry point for the Library feature. Composes the hierarchical
/// Library IA (Favorites / Browse / Recently Opened) inside a NavigationStack
/// or NavigationSplitView depending on size class. App passes the live
/// adapters (Plan #3) plus a closure that materialises the License view.
@MainActor
public struct LibraryRootView<LicenseContent: View>: View {
    @State private var viewModel: LibraryViewModel
    private let onOpenScore: (ScoreItem) -> Void
    private let licenseContent: () -> LicenseContent

    public init(
        repository: any ScoreLibraryRepository,
        importer: any ScoreFileImporter,
        gateway: any ScoreFileGateway,
        onOpenScore: @escaping (ScoreItem) -> Void,
        @ViewBuilder licenseContent: @escaping () -> LicenseContent
    ) {
        _viewModel = State(
            wrappedValue: LibraryViewModel(
                repository: repository, importer: importer, gateway: gateway
            )
        )
        self.onOpenScore = onOpenScore
        self.licenseContent = licenseContent
    }

    public var body: some View {
        // Filled in by Task 15.
        Text("Library")
            .navigationTitle("Library")
    }
}
