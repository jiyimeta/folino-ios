import Domain
import Foundation
import Yams

public protocol VersionHistoryLoader: Sendable {
    func load() throws -> [VersionHistoryEntry]
}

public struct DefaultVersionHistoryLoader: VersionHistoryLoader, @unchecked Sendable {
    /// Bundle is read-only after init; safe to send.
    public enum LoadError: Error {
        case resourceNotFound(name: String)
        case unparseableRoot
    }

    private let bundle: Bundle
    private let resourceName: String

    public init(bundle: Bundle = .main, resourceName: String = "VersionHistory") {
        self.bundle = bundle
        self.resourceName = resourceName
    }

    public func load() throws -> [VersionHistoryEntry] {
        guard let url = bundle.url(forResource: resourceName, withExtension: "yml") else {
            throw LoadError.resourceNotFound(name: resourceName)
        }
        let yaml = try String(contentsOf: url, encoding: .utf8)
        // Parse to the YAML node tree first so we can iterate the top-level
        // sequence and re-decode each child independently — a single malformed
        // entry is then skipped instead of poisoning the whole load.
        guard let root = try Yams.compose(yaml: yaml) else {
            throw LoadError.unparseableRoot
        }
        guard case let .sequence(sequence) = root else {
            throw LoadError.unparseableRoot
        }
        let decoder = YAMLDecoder()
        return sequence.compactMap { node in
            guard let yamlForEntry = try? Yams.serialize(node: node) else { return nil }
            return try? decoder.decode(VersionHistoryEntry.self, from: yamlForEntry)
        }
    }
}
