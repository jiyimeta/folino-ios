import Foundation
import SettingsLogic

/// swift-java entry point for Kotlin `SettingsJNI.nativeLoadVersionHistory`.
/// Takes the JSON asset bytes, returns the wirelet-encoded entry list.
public func nativeLoadVersionHistory(jsonBytes: Data) -> Data {
    versionHistoryWirePayload(jsonData: jsonBytes)
}
