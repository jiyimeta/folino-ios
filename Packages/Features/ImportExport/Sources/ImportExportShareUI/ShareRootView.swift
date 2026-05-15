// Sources/ImportExportShareUI/ShareRootView.swift
import Domain
import ImportExportAppGroup
import SwiftUI
import UtilityCore

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
    @State private var isFinalizing = false
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
                .padding(20)
                .navigationTitle(Text("share_extension.title", bundle: .module))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button {
                            session.discard(token: token)
                            onComplete(.init(outcome: .cancelled))
                        } label: {
                            Text("share_extension.cancel", bundle: .module)
                        }
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
            errorView(message: fatalMessage)
        } else if let summary {
            loadedView(summary: summary)
        } else {
            loadingView
        }
    }

    private func errorView(message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.largeTitle)
                .foregroundStyle(.orange)
            Text(message).multilineTextAlignment(.center)
        }
    }

    private func loadedView(summary: IngestSummary) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            FileSummary(files: summary.acceptedFiles, unsupportedCount: summary.unsupportedCount)
            if summary.acceptedFiles.isEmpty {
                Text("share_extension.no_supported_files", bundle: .module)
                    .foregroundStyle(.secondary)
            } else {
                PlaylistPicker(entries: playlists, selection: $selection)
            }
            Spacer(minLength: 0)
            ActionButtons(
                disabled: summary.acceptedFiles.isEmpty || isFinalizing,
                onSave: { finalize(decision: .save(selection)) },
                onSaveAndOpen: { finalize(decision: .saveAndOpen(selection)) },
            )
        }
    }

    private var loadingView: some View {
        VStack(spacing: 12) {
            ProgressView().controlSize(.large)
            Text("share_extension.loading", bundle: .module)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func finalize(decision: ShareDecision) {
        guard let summary else { return }
        isFinalizing = true
        do {
            let url = try session.finalize(
                token: token,
                files: summary.acceptedFiles,
                decision: decision,
            )
            onComplete(.init(outcome: .submitted(openURL: url)))
        } catch {
            isFinalizing = false
            fatalMessage = String(describing: error)
        }
    }
}

#Preview("Empty playlists") {
    let tmp = FileManager.default.temporaryDirectory
        .appending(path: "share-preview-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    return ShareRootView(
        session: ShareSession(appGroupContainer: tmp, clock: SystemClock()),
        items: [],
        onComplete: { _ in },
    )
}
