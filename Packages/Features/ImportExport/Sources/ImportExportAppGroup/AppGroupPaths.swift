// Sources/ImportExportAppGroup/AppGroupPaths.swift
import Foundation

public enum AppGroupIDs {
    public static let identifier = "group.com.KeyNumber.Folino"
}

public enum AppGroupPaths {
    public static let playlistsIndexFilename = "playlists.json"
    public static let incomingImportsDirname = "IncomingImports"
    public static let intentFilename = "intent.json"
    public static let filesDirname = "files"

    public static func container() -> URL? {
        FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: AppGroupIDs.identifier,
        )
    }

    public static func playlistsIndexURL(in container: URL) -> URL {
        container.appending(path: playlistsIndexFilename, directoryHint: .notDirectory)
    }

    public static func incomingImportsURL(in container: URL) -> URL {
        container.appending(path: incomingImportsDirname, directoryHint: .isDirectory)
    }

    public static func tokenURL(token: UUID, in container: URL) -> URL {
        incomingImportsURL(in: container)
            .appending(path: token.uuidString, directoryHint: .isDirectory)
    }

    public static func tokenIntentURL(token: UUID, in container: URL) -> URL {
        tokenURL(token: token, in: container)
            .appending(path: intentFilename, directoryHint: .notDirectory)
    }

    public static func tokenFilesURL(token: UUID, in container: URL) -> URL {
        tokenURL(token: token, in: container)
            .appending(path: filesDirname, directoryHint: .isDirectory)
    }
}
