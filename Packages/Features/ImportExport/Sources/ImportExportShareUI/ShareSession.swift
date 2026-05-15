// Sources/ImportExportShareUI/ShareSession.swift
import Domain
import Foundation
import ImportExportAppGroup
import os
import UIKit
import UniformTypeIdentifiers
import UtilityCore

@MainActor
public final class ShareSession {
    private let appGroupContainer: URL
    private let clock: any Clock
    private let logger = Logger(subsystem: "com.KeyNumber.Folino", category: "ShareSession")

    public init(appGroupContainer: URL, clock: any Clock) {
        self.appGroupContainer = appGroupContainer
        self.clock = clock
    }

    public func loadPlaylists() -> [PlaylistsIndex.Entry] {
        let url = AppGroupPaths.playlistsIndexURL(in: appGroupContainer)
        guard let data = try? Data(contentsOf: url),
              let index = try? JSONDecoder().decode(PlaylistsIndex.self, from: data)
        else {
            return []
        }
        return index.playlists
    }

    /// Copies `NSItemProvider` items into the App Group container under `token/files/`.
    ///
    /// UTI strategy mirrors the main app's `ScoreFileTypes.allowed`:
    /// match specific score UTIs first, then fall back to parent UTIs
    /// (`public.xml`, `public.zip-archive`, `public.midi-audio`) so cloud
    /// providers that don't propagate the score-specific identifier still
    /// reach us. A filename-extension allow-list is the final guard.
    public func ingest(items: [NSItemProvider], token: UUID) async -> IngestSummary {
        let filesURL = AppGroupPaths.tokenFilesURL(token: token, in: appGroupContainer)
        try? FileManager.default.createDirectory(at: filesURL, withIntermediateDirectories: true)

        var accepted: [IncomingShareIntent.File] = []
        var unsupported = 0

        for provider in items {
            let matched = Self.candidateTypeIdentifiers
                .first { provider.hasItemConformingToTypeIdentifier($0) }
            guard let matched else {
                logger.info("provider registered no usable UTI: \(provider.registeredTypeIdentifiers)")
                unsupported += 1
                continue
            }
            do {
                let url = try await loadFileRepresentation(provider: provider, typeIdentifier: matched)
                guard Self.acceptedExtensions.contains(url.pathExtension.lowercased()) else {
                    logger.info("rejecting unsupported extension: \(url.lastPathComponent)")
                    unsupported += 1
                    continue
                }
                let name = url.lastPathComponent
                let dest = filesURL.appending(path: name, directoryHint: .notDirectory)
                if FileManager.default.fileExists(atPath: dest.path) {
                    try? FileManager.default.removeItem(at: dest)
                }
                try FileManager.default.copyItem(at: url, to: dest)
                accepted.append(.init(relativePath: "files/\(name)", originalName: name))
            } catch {
                logger.error("ingest failure: \(String(describing: error))")
                unsupported += 1
            }
        }

        return IngestSummary(token: token, acceptedFiles: accepted, unsupportedCount: unsupported)
    }

    private static let candidateTypeIdentifiers: [String] = [
        // Specific UTIs whichever app on the device owns the registration.
        "org.musescore.mscz",
        "org.musescore.mscx",
        "com.recordare.musicxml",
        "com.recordare.musicxml.zipped",
        // Parent fallbacks for cloud providers handing us generic UTIs and
        // devices where a sibling app's UTI doesn't conform to ours.
        "public.zip-archive",
        "public.xml",
        "public.midi-audio",
    ]

    private static let acceptedExtensions: Set = [
        "mscz", "mscx", "musicxml", "mxl", "xml", "midi", "mid",
    ]

    public func finalize(
        token: UUID,
        files: [IncomingShareIntent.File],
        decision: ShareDecision,
    ) throws -> URL {
        let (playlistID, newPlaylistName) = decisionToFields(decision.choice)
        let intent = IncomingShareIntent(
            schemaVersion: 1,
            token: token,
            createdAt: clock.now(),
            playlistID: playlistID,
            newPlaylistName: newPlaylistName,
            openAfter: decision.openAfter,
            files: files,
        )
        let data = try JSONEncoder().encode(intent)
        let dest = AppGroupPaths.tokenIntentURL(token: token, in: appGroupContainer)
        let tmp = dest.appendingPathExtension("tmp")
        try data.write(to: tmp, options: .atomic)
        _ = try FileManager.default.replaceItemAt(dest, withItemAt: tmp)
        return ShareTokenURLBuilder.build(token: token, openAfter: decision.openAfter)
    }

    public func discard(token: UUID) {
        try? FileManager.default.removeItem(at: AppGroupPaths.tokenURL(token: token, in: appGroupContainer))
    }

    // MARK: - Helpers

    private func decisionToFields(_ choice: PlaylistChoice) -> (PlaylistID?, String?) {
        switch choice {
        case .libraryOnly: (nil, nil)
        case let .existing(id): (id, nil)
        case let .createNew(name): (nil, name.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    private func loadFileRepresentation(
        provider: NSItemProvider,
        typeIdentifier: String,
    ) async throws -> URL {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<URL, Error>) in
            _ = provider.loadFileRepresentation(forTypeIdentifier: typeIdentifier) { url, error in
                if let error {
                    cont.resume(throwing: error)
                } else if let url {
                    do {
                        let dst = FileManager.default.temporaryDirectory
                            .appending(path: "share-\(UUID().uuidString)-\(url.lastPathComponent)")
                        if FileManager.default.fileExists(atPath: dst.path) {
                            try FileManager.default.removeItem(at: dst)
                        }
                        try FileManager.default.copyItem(at: url, to: dst)
                        cont.resume(returning: dst)
                    } catch {
                        cont.resume(throwing: error)
                    }
                } else {
                    cont.resume(throwing: NSError(domain: "ShareSession", code: -1))
                }
            }
        }
    }
}

/// Mirror of ShareTokenURL.build from the ImportExport main-app library.
/// Duplicated here so ImportExportShareUI does not need to depend on ImportExport.
private enum ShareTokenURLBuilder {
    static func build(token: UUID, openAfter: Bool) -> URL {
        var c = URLComponents()
        c.scheme = "folino"
        c.host = "import"
        c.queryItems = [
            URLQueryItem(name: "token", value: token.uuidString),
            URLQueryItem(name: "open", value: openAfter ? "true" : "false"),
        ]
        guard let url = c.url else {
            preconditionFailure("Failed to build folino://import URL for token \(token)")
        }
        return url
    }
}
