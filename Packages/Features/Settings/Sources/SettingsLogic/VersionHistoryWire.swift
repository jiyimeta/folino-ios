import Wirelet

/// Wire-format representation of a single version-history entry. Used as the Swift-side type for the
/// JNI bridge that transfers version history from the iOS host to the Kotlin/Android client.
///
/// Both `[String]` fields and nested `[@WireFormat]` arrays are supported by swift-wirelet v0.1.0-alpha.2
/// (Array conforms to WireFormatEncodable/Decodable where Element also conforms).
@WireFormat
public struct VersionHistoryWire: Equatable {
    public var version: String
    public var descriptions: [String]
    public init(version: String, descriptions: [String]) {
        self.version = version
        self.descriptions = descriptions
    }
}

/// Top-level wire envelope holding all version history entries. Encoding this and passing the `Data` over
/// JNI lets Kotlin decode the full list in one call via the generated `VersionHistoryWireListCodec`.
@WireFormat
public struct VersionHistoryWireList: Equatable {
    public var entries: [VersionHistoryWire]
    public init(entries: [VersionHistoryWire]) {
        self.entries = entries
    }
}
