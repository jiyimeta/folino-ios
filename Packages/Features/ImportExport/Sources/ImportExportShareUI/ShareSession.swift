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
    /// `NSItemProvider` from `Files` etc. doesn't reliably advertise the
    /// specific score UTIs even when the main app declares them — many
    /// share-sheet sources only set `public.data`. We try the specific
    /// UTIs and parent UTIs first (so the load uses the most precise
    /// type identifier available), then fall back to `public.data` /
    /// `public.file-url` so we still receive the bytes. The filename
    /// extension allow-list is the real gate.
    public func ingest(items: [NSItemProvider], token: UUID) async -> IngestSummary {
        let filesURL = AppGroupPaths.tokenFilesURL(token: token, in: appGroupContainer)
        try? FileManager.default.createDirectory(at: filesURL, withIntermediateDirectories: true)

        var accepted: [IncomingShareIntent.File] = []
        var unsupported = 0

        logger.notice(
            "ingest start build=\(Self.buildMarker, privacy: .public) count=\(items.count, privacy: .public)",
        )
        for (index, provider) in items.enumerated() {
            let ids = provider.registeredTypeIdentifiers.joined(separator: ",")
            logger.notice("provider[\(index, privacy: .public)] type IDs: \(ids, privacy: .public)")
            do {
                guard let url = try await loadProviderFile(provider: provider, index: index) else {
                    unsupported += 1
                    continue
                }
                let ext = url.pathExtension.lowercased()
                let name = url.lastPathComponent
                logger.notice("provider[\(index, privacy: .public)] loaded name=\(name, privacy: .public)")
                logger.notice("provider[\(index, privacy: .public)] ext=\(ext, privacy: .public)")
                guard Self.acceptedExtensions.contains(ext) else {
                    logger.notice("provider[\(index, privacy: .public)] rejected by extension allow-list")
                    unsupported += 1
                    continue
                }
                let dest = filesURL.appending(path: name, directoryHint: .notDirectory)
                if FileManager.default.fileExists(atPath: dest.path) {
                    try? FileManager.default.removeItem(at: dest)
                }
                try FileManager.default.copyItem(at: url, to: dest)
                accepted.append(.init(relativePath: "files/\(name)", originalName: name))
            } catch {
                let errDesc = String(describing: error)
                logger.error(
                    "provider[\(index, privacy: .public)] failure: \(errDesc, privacy: .public)",
                )
                unsupported += 1
            }
        }
        logger.notice(
            "ingest done; accepted=\(accepted.count, privacy: .public) unsupported=\(unsupported, privacy: .public)",
        )

        return IngestSummary(token: token, acceptedFiles: accepted, unsupportedCount: unsupported)
    }

    /// Picks the most specific usable UTI from a provider's registered list
    /// and loads the file representation. URL-only items (where the only
    /// usable identifier is `public.url` / `public.file-url`) need the
    /// `loadItem(forTypeIdentifier:)` path with security-scoped access.
    private func loadProviderFile(provider: NSItemProvider, index: Int) async throws -> URL? {
        let registered = provider.registeredTypeIdentifiers
        let specific = registered.first { !Self.urlOnlyIdentifiers.contains($0) }
        if let specific {
            logger.notice("provider[\(index, privacy: .public)] using specific UTI \(specific, privacy: .public)")
            return try await loadFileRepresentation(provider: provider, typeIdentifier: specific)
        }
        if registered.contains("public.file-url") {
            logger.notice("provider[\(index, privacy: .public)] using public.file-url item path")
            return try await loadFileURLItem(provider: provider)
        }
        logger.notice("provider[\(index, privacy: .public)] no usable UTI; skipping")
        return nil
    }

    private func loadFileURLItem(provider: NSItemProvider) async throws -> URL {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<URL, Error>) in
            provider.loadItem(forTypeIdentifier: "public.file-url", options: nil) { item, error in
                if let error {
                    cont.resume(throwing: error)
                    return
                }
                let url: URL? = (item as? URL)
                    ?? (item as? NSURL).map { $0 as URL }
                    ?? (item as? Data).flatMap { URL(dataRepresentation: $0, relativeTo: nil, isAbsolute: true) }
                guard let url else {
                    cont.resume(throwing: NSError(
                        domain: "ShareSession", code: -2,
                        userInfo: [NSLocalizedDescriptionKey: "loadItem returned non-URL"],
                    ))
                    return
                }
                do {
                    let dst = FileManager.default.temporaryDirectory
                        .appending(path: "share-\(UUID().uuidString)-\(url.lastPathComponent)")
                    if FileManager.default.fileExists(atPath: dst.path) {
                        try FileManager.default.removeItem(at: dst)
                    }
                    let accessing = url.startAccessingSecurityScopedResource()
                    defer { if accessing { url.stopAccessingSecurityScopedResource() } }
                    try FileManager.default.copyItem(at: url, to: dst)
                    cont.resume(returning: dst)
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
    }

    private static let urlOnlyIdentifiers: Set = [
        "public.url", "public.file-url", "public.data", "public.item",
    ]

    private static let acceptedExtensions: Set = [
        "mscz", "mscx", "musicxml", "mxl", "xml", "midi", "mid",
    ]

    /// Bump this string per device-deploy iteration so logs unambiguously
    /// reveal whether the latest binary is running. Format is free-form.
    private static let buildMarker = "r3-2026-05-18"

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
