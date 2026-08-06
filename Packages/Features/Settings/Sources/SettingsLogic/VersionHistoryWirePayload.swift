import Domain
import Foundation

/// Encodes the version history from `ymlData` into a wirelet-format `Data` payload ready for JNI transfer.
///
/// `languageTag` is the host's own language (an IETF BCP 47 tag such as `ja-JP`), because the wire carries
/// post-localization strings and the JNI library's `Locale.current` reflects the Swift runtime's environment
/// rather than the device's language setting. An empty tag falls back to `Locale.current`.
///
/// On malformed input the function returns an empty-list payload rather than throwing, so the Kotlin side
/// always receives a valid (possibly empty) `VersionHistoryWireList`.
public func versionHistoryWirePayload(ymlData: Data, languageTag: String = "") -> Data {
    let locale = languageTag.isEmpty ? Locale.current : Locale(identifier: languageTag)
    let entries = (try? YAMLVersionHistoryLoader(data: ymlData, locale: locale).load()) ?? []
    let wire = entries.map { VersionHistoryWire(version: $0.version.description, descriptions: $0.descriptions) }
    return VersionHistoryWireList(entries: wire).encodeToData()
}
