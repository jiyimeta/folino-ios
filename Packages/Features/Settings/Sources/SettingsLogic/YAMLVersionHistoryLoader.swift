import Domain
import Foundation
import Yams

/// Shared `VersionHistoryLoader` that parses YAML `Data` into `[VersionHistoryEntry]`. Used by both the iOS
/// bundle loader and the Android JNI bridge, so the schema and locale-selection logic stay single-sourced in
/// `Domain.VersionHistoryEntry`.
///
/// Parses the YAML node tree first and re-decodes each top-level element independently, so a single malformed
/// entry is skipped rather than poisoning the whole load. Throws when the document root is missing or is not a
/// sequence; callers that need resilience (the JNI helper) wrap the call in `try?`.
public struct YAMLVersionHistoryLoader: VersionHistoryLoader {
    public enum LoadError: Error, Equatable {
        case invalidEncoding
        case unparseableRoot
    }

    private let data: Data
    public init(data: Data) {
        self.data = data
    }

    public func load() throws -> [VersionHistoryEntry] {
        guard let yaml = String(data: data, encoding: .utf8) else {
            throw LoadError.invalidEncoding
        }
        guard let root = try Yams.compose(yaml: yaml) else {
            throw LoadError.unparseableRoot
        }
        guard case let .sequence(sequence) = root else {
            throw LoadError.unparseableRoot
        }
        let decoder = YAMLDecoder()
        return sequence.compactMap { try? decoder.decode(VersionHistoryEntry.self, from: $0) }
    }
}
