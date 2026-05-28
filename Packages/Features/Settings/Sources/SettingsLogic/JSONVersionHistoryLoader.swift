import Domain
import Foundation

/// A `VersionHistoryLoader` that reads from JSON-encoded `Data` using the same on-disk format as the Android
/// `VersionHistory.json` asset. Each element is a `{"version": "X.Y.Z", "descriptions": [...]}` object where
/// `descriptions` is an array of locale-keyed objects matching `VersionHistoryEntry`'s custom `init(from:)`.
public struct JSONVersionHistoryLoader: VersionHistoryLoader {
    private let data: Data
    public init(data: Data) {
        self.data = data
    }

    public func load() throws -> [VersionHistoryEntry] {
        try JSONDecoder().decode([VersionHistoryEntry].self, from: data)
    }
}

/// Encodes the version history from `jsonData` into a wirelet-format `Data` payload ready for JNI transfer.
///
/// On malformed input the function returns an empty-list payload rather than throwing, so the Kotlin side
/// always receives a valid (possibly empty) `VersionHistoryWireList`.
public func versionHistoryWirePayload(jsonData: Data) -> Data {
    let entries = (try? JSONVersionHistoryLoader(data: jsonData).load()) ?? []
    let wire = entries.map { VersionHistoryWire(version: $0.version.description, descriptions: $0.descriptions) }
    return VersionHistoryWireList(entries: wire).encodeToData()
}
