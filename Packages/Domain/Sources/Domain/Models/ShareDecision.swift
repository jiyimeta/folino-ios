import Foundation

/// Where shared files land: just the Library, an existing playlist, or a brand-new playlist.
public enum PlaylistChoice: Sendable, Equatable {
    case libraryOnly
    case existing(PlaylistID)
    case createNew(name: String)
}

/// The user's full share decision: destination plus whether to open the imported score afterward.
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
