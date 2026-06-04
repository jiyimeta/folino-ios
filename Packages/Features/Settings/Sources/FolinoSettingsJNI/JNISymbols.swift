import Foundation
import SettingsLogic

/// swift-java entry point for Kotlin `SettingsJNI.nativeLoadVersionHistory`.
/// Takes the YAML asset bytes, returns the wirelet-encoded entry list.
public func nativeLoadVersionHistory(ymlBytes: Data) -> Data {
    versionHistoryWirePayload(ymlData: ymlBytes)
}
