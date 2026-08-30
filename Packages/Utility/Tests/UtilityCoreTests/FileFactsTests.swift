import Foundation
import Testing
@testable import UtilityCore

@Suite("FileFacts")
struct FileFactsTests {
    @Test
    func `hashAndSize returns the SHA-256 hex digest and byte count`() throws {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "filefacts-\(UUID().uuidString).bin")
        try Data("folino".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let facts = try FileFacts.hashAndSize(of: url)
        #expect(facts.sizeBytes == 6)
        // echo -n folino | shasum -a 256
        #expect(facts.contentHash == "c4358a122a634205d05731d3c99a25dc5d06647c459c2b5d3375b0945ba7d9eb")
    }
}
