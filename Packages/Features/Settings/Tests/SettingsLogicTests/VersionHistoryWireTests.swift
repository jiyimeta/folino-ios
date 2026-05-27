@testable import SettingsLogic
import Testing

struct VersionHistoryWireTests {
    @Test func `round trips list payload`() throws {
        let entries = [
            VersionHistoryWire(version: "1.5.1", descriptions: ["a", "b"]),
            VersionHistoryWire(version: "1.5.0", descriptions: ["c"]),
        ]
        let bytes = VersionHistoryWireList(entries: entries).encodeToData()
        let decoded = try VersionHistoryWireList(decoding: bytes)
        #expect(decoded.entries == entries)
    }
}
