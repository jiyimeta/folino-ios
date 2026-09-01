import Domain
import ImportExportAppGroup
import SwiftUI
import UtilityCore
import UtilityUI

public struct ShareCompletion: Sendable {
    public let outcome: Outcome

    public enum Outcome: Sendable {
        case cancelled
        case submitted(openURL: URL)
    }

    public init(outcome: Outcome) {
        self.outcome = outcome
    }
}

public struct ShareRootView: View {
    @State private var summary: IngestSummary?
    @State private var playlists: [PlaylistsIndex.Entry] = []
    @State private var selection: PlaylistChoice = .libraryOnly
    @State private var fatalMessage: String?

    private let session: ShareSession
    private let items: [NSItemProvider]
    private let onComplete: (ShareCompletion) -> Void
    private let token = UUID()

    public init(
        session: ShareSession,
        items: [NSItemProvider],
        onComplete: @escaping (ShareCompletion) -> Void,
    ) {
        self.session = session
        self.items = items
        self.onComplete = onComplete
    }

    public var body: some View {
        NavigationStack {
            content
                .navigationTitle(Text("share_extension.title", bundle: .module))
                .inlineNavigationTitleCompat()
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button {
                            session.discard(token: token)
                            onComplete(.init(outcome: .cancelled))
                        } label: {
                            Text("share_extension.cancel", bundle: .module)
                        }
                    }

                    ToolbarItem(placement: .confirmationAction) {
                        Button {
                            finalize(decision: .saveAndOpen(selection))
                        } label: {
                            Image(systemName: "checkmark")
                        }
                        .glassProminentButtonStyleCompat()
                        .disabled(summary?.acceptedFiles.isEmpty ?? true)
                    }
                }
                .task {
                    let result = await session.ingest(items: items, token: token)
                    summary = result
                    playlists = session.loadPlaylists()
                }
        }
    }

    @ViewBuilder
    private var content: some View {
        if let fatalMessage {
            ShareErrorView(message: fatalMessage)
        } else if let summary {
            loadedView(summary: summary)
        } else {
            ShareLoadingView()
        }
    }

    private func loadedView(summary: IngestSummary) -> some View {
        ShareLoadedContent(
            acceptedFiles: summary.acceptedFiles,
            unsupportedCount: summary.unsupportedCount,
            playlists: playlists,
            selection: $selection,
        )
    }

    private func finalize(decision: ShareDecision) {
        guard let summary else { return }
        do {
            let url = try session.finalize(
                token: token,
                files: summary.acceptedFiles,
                decision: decision,
            )
            onComplete(.init(outcome: .submitted(openURL: url)))
        } catch {
            fatalMessage = String(describing: error)
        }
    }
}

/// The share screen's terminal error state. Pulled out of `ShareRootView.content` to mirror `ShareLoadedContent`.
private struct ShareErrorView: View {
    let message: String

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.largeTitle)
                .foregroundStyle(.orange)
            Text(message).multilineTextAlignment(.center)
        }
        .padding(20)
    }
}

/// The share screen's loading state while `NSItemProvider` ingestion is in flight. Pulled out of
/// `ShareRootView.content` to mirror `ShareLoadedContent`.
private struct ShareLoadingView: View {
    var body: some View {
        VStack(spacing: 12) {
            ProgressView().controlSize(.large)
            Text("share_extension.loading", bundle: .module)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Internal content of the loaded share screen. Pulled out of `ShareRootView.loadedView` so SwiftUI previews can drive
/// it without having to fake `NSItemProvider` ingestion.
private struct ShareLoadedContent: View {
    let acceptedFiles: [IncomingShareIntent.File]
    let unsupportedCount: Int
    let playlists: [PlaylistsIndex.Entry]
    @Binding var selection: PlaylistChoice

    var body: some View {
        Form {
            FileSummarySection(files: acceptedFiles, unsupportedCount: unsupportedCount)
            if !acceptedFiles.isEmpty {
                PlaylistPickerSection(entries: playlists, selection: $selection)
            }
        }
    }
}

// MARK: - Previews

#Preview("Empty (loading from empty App Group)") {
    let tmp = FileManager.default.temporaryDirectory
        .appending(path: "share-preview-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    return ShareRootView(
        session: ShareSession(appGroupContainer: tmp, clock: SystemClock()),
        items: [],
        onComplete: { _ in },
    )
}

#Preview("Single file, no playlists") {
    PreviewLoaded(
        files: [
            .init(
                relativePath: "files/Beethoven Sonata No. 14.mscz",
                originalName: "Beethoven Sonata No. 14.mscz",
            ),
        ],
        playlists: [],
    )
}

#Preview("Single file, several playlists") {
    PreviewLoaded(
        files: [
            .init(
                relativePath: "files/Goldberg Variations.mscz",
                originalName: "Goldberg Variations.mscz",
            ),
        ],
        playlists: [
            .init(id: PlaylistID(), name: "Practice"),
            .init(id: PlaylistID(), name: "Jazz studies"),
            .init(id: PlaylistID(), name: "Sight reading"),
        ],
    )
}

#Preview("Multiple files, several playlists") {
    PreviewLoaded(
        files: [
            .init(relativePath: "files/First.mscz", originalName: "First.mscz"),
            .init(relativePath: "files/Second.musicxml", originalName: "Second.musicxml"),
            .init(relativePath: "files/Third.midi", originalName: "Third.midi"),
        ],
        playlists: [
            .init(id: PlaylistID(), name: "Practice"),
            .init(id: PlaylistID(), name: "Concert prep"),
        ],
    )
}

#Preview("With unsupported files") {
    PreviewLoaded(
        files: [
            .init(relativePath: "files/MyScore.mscz", originalName: "MyScore.mscz"),
        ],
        unsupportedCount: 2,
        playlists: [
            .init(id: PlaylistID(), name: "Practice"),
        ],
    )
}

private struct PreviewLoaded: View {
    let files: [IncomingShareIntent.File]
    var unsupportedCount = 0
    let playlists: [PlaylistsIndex.Entry]
    @State private var selection: PlaylistChoice = .libraryOnly

    var body: some View {
        NavigationStack {
            ShareLoadedContent(
                acceptedFiles: files,
                unsupportedCount: unsupportedCount,
                playlists: playlists,
                selection: $selection,
            )
            .navigationTitle(Text("share_extension.title", bundle: .module))
            .inlineNavigationTitleCompat()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button {} label: {
                        Text("share_extension.cancel", bundle: .module)
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {} label: { Image(systemName: "checkmark") }
                        .glassProminentButtonStyleCompat()
                        .disabled(files.isEmpty)
                }
            }
        }
        .environment(\.locale, Locale(identifier: "ja"))
    }
}
