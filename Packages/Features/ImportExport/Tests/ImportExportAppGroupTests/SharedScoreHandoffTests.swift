import Foundation
import ImportExportAppGroup
import Testing

@Suite("SharedScorePaths")
struct SharedScorePathsTests {
    @Test func `builds the staged hand-off layout under the shared container`() {
        let container = URL(fileURLWithPath: "/tmp/shared")
        let token = "5C9B7F8E-1A2B-4C3D-8E4F-6A7B8C9D0E1F"

        #expect(SharedScorePaths.incomingScoresURL(in: container).path == "/tmp/shared/IncomingScores")
        #expect(SharedScorePaths.tokenURL(token: token, in: container).path == "/tmp/shared/IncomingScores/\(token)")
        #expect(
            SharedScorePaths.tokenIntentURL(token: token, in: container).path
                == "/tmp/shared/IncomingScores/\(token)/intent.json",
        )
        #expect(
            SharedScorePaths.tokenFilesURL(token: token, in: container).path
                == "/tmp/shared/IncomingScores/\(token)/files",
        )
        #expect(SharedScorePaths.capabilitiesURL(in: container).path == "/tmp/shared/folino/capabilities.json")
    }

    @Test(arguments: [
        "5C9B7F8E-1A2B-4C3D-8E4F-6A7B8C9D0E1F",
        "abc123",
        "a_b-c",
    ])
    func `accepts tokens that are safe path components`(token: String) {
        #expect(SharedScorePaths.isValidToken(token))
    }

    @Test(arguments: [
        "",
        "..",
        "../../Soundfonts",
        "a/b",
        "a b",
        "tok.en",
        "トークン",
    ])
    func `rejects tokens that could escape the hand-off directory`(token: String) {
        #expect(!SharedScorePaths.isValidToken(token))
    }
}

@Suite("CapabilityStampWriter")
struct CapabilityStampWriterTests {
    private func makeContainer() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "caps-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func `stamps the capability file a sibling app looks for`() throws {
        let container = try makeContainer()
        defer { try? FileManager.default.removeItem(at: container) }

        try CapabilityStampWriter(sharedContainer: container).stamp(appVersion: "1.9.0")

        let data = try Data(contentsOf: SharedScorePaths.capabilitiesURL(in: container))
        let caps = try JSONDecoder().decode(FolinoCapabilities.self, from: data)
        #expect(caps.protocolVersion == 1)
        #expect(caps.folinoAppVersion == "1.9.0")
    }

    @Test func `re-stamping overwrites the previous app version`() throws {
        let container = try makeContainer()
        defer { try? FileManager.default.removeItem(at: container) }
        let writer = CapabilityStampWriter(sharedContainer: container)

        try writer.stamp(appVersion: "1.9.0")
        try writer.stamp(appVersion: "1.10.0")

        let data = try Data(contentsOf: SharedScorePaths.capabilitiesURL(in: container))
        let caps = try JSONDecoder().decode(FolinoCapabilities.self, from: data)
        #expect(caps.folinoAppVersion == "1.10.0")
    }
}
