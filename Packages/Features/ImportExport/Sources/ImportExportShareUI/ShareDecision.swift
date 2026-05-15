// Sources/ImportExportShareUI/ShareDecision.swift
import Domain
import Foundation
import ImportExportAppGroup

public enum PlaylistChoice: Sendable, Equatable {
    case libraryOnly
    case existing(PlaylistID)
    case createNew(name: String)
}

public enum ShareDecision: Sendable, Equatable {
    case save(PlaylistChoice)
    case saveAndOpen(PlaylistChoice)

    public var openAfter: Bool {
        if case .saveAndOpen = self { return true }
        return false
    }

    public var choice: PlaylistChoice {
        switch self {
        case let .save(c), let .saveAndOpen(c): c
        }
    }
}

public struct IngestSummary: Sendable {
    public let token: UUID
    public let acceptedFiles: [IncomingShareIntent.File]
    public let unsupportedCount: Int

    public init(token: UUID, acceptedFiles: [IncomingShareIntent.File], unsupportedCount: Int) {
        self.token = token
        self.acceptedFiles = acceptedFiles
        self.unsupportedCount = unsupportedCount
    }
}
