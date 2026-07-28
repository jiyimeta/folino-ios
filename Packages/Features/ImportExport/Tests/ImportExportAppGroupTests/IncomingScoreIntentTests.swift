import Foundation
import ImportExportAppGroup
import Testing

@Suite("IncomingScoreIntent")
struct IncomingScoreIntentTests {
    /// Byte-for-byte what the sibling app stages: ISO-8601 `createdAt`, a `String` token, and an advisory `format`.
    /// The sibling has a matching pinned-bytes test on its side, so this pair is the contract's regression guard.
    private static let stagedJSON = """
    {
      "createdAt" : "1970-01-01T00:01:40Z",
      "files" : [
        {
          "format" : "musicXML",
          "originalName" : "Etude.musicxml",
          "relativePath" : "files/Etude.musicxml"
        }
      ],
      "openAfter" : true,
      "schemaVersion" : 1,
      "source" : "vocaltuner",
      "token" : "5C9B7F8E-1A2B-4C3D-8E4F-6A7B8C9D0E1F"
    }
    """

    @Test func `decodes the intent a sibling app stages`() throws {
        let intent = try IncomingScoreIntent.decoder()
            .decode(IncomingScoreIntent.self, from: Data(Self.stagedJSON.utf8))

        #expect(intent.schemaVersion == 1)
        #expect(intent.token == "5C9B7F8E-1A2B-4C3D-8E4F-6A7B8C9D0E1F")
        #expect(intent.createdAt == Date(timeIntervalSince1970: 100))
        #expect(intent.source == "vocaltuner")
        #expect(intent.openAfter)
        #expect(intent.files.count == 1)
        #expect(intent.files[0].relativePath == "files/Etude.musicxml")
        #expect(intent.files[0].originalName == "Etude.musicxml")
        #expect(intent.files[0].format == "musicXML")
    }

    @Test func `a plain decoder cannot read the ISO-8601 createdAt`() {
        // Guards the reason `decoder()` exists: the default strategy expects a numeric date and would reject every
        // hand-off, silently degrading one-tap to "nothing happened".
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(IncomingScoreIntent.self, from: Data(Self.stagedJSON.utf8))
        }
    }

    @Test func `format is optional so an unlabelled file still decodes`() throws {
        let json = """
        {"schemaVersion":1,"token":"abc","createdAt":"1970-01-01T00:01:40Z","source":"vocaltuner",
         "openAfter":false,"files":[{"relativePath":"files/a.mxl","originalName":"a.mxl"}]}
        """
        let intent = try IncomingScoreIntent.decoder().decode(IncomingScoreIntent.self, from: Data(json.utf8))

        #expect(intent.files[0].format == nil)
        #expect(!intent.openAfter)
    }

    @Test func `round-trips through the contract encoder`() throws {
        let original = try IncomingScoreIntent.decoder()
            .decode(IncomingScoreIntent.self, from: Data(Self.stagedJSON.utf8))
        let data = try IncomingScoreIntent.encoder().encode(original)

        #expect(try IncomingScoreIntent.decoder().decode(IncomingScoreIntent.self, from: data) == original)
        let json = try #require(String(bytes: data, encoding: .utf8))
        #expect(json.contains("\"createdAt\":\"1970-01-01T00:01:40Z\""))
    }
}
