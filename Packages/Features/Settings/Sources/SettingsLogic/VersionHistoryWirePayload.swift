import Domain
import Foundation

/// Encodes the version history from `ymlData` into a wirelet-format `Data` payload ready for JNI transfer.
///
/// On malformed input the function returns an empty-list payload rather than throwing, so the Kotlin side
/// always receives a valid (possibly empty) `VersionHistoryWireList`.
public func versionHistoryWirePayload(ymlData: Data) -> Data {
    let entries = (try? YAMLVersionHistoryLoader(data: ymlData).load()) ?? []
    let wire = entries.map { VersionHistoryWire(version: $0.version.description, descriptions: $0.descriptions) }
    return VersionHistoryWireList(entries: wire).encodeToData()
}
