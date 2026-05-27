import Domain

public protocol VersionHistoryLoader: Sendable {
    func load() throws -> [VersionHistoryEntry]
}
