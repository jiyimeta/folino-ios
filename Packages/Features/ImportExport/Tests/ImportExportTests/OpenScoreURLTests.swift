import Foundation
import ImportExport
import Testing

@Suite("OpenScoreURL")
struct OpenScoreURLTests {
    @Test func `parses the URL the shipped sibling opens`() throws {
        // The shipped build omits `open` entirely — the contract is `folino://open-score?token=<token>`.
        let url = try #require(URL(string: "folino://open-score?token=5C9B7F8E-1A2B-4C3D-8E4F-6A7B8C9D0E1F"))

        let parsed = try #require(OpenScoreURL.parse(url))

        #expect(parsed.token == "5C9B7F8E-1A2B-4C3D-8E4F-6A7B8C9D0E1F")
        #expect(parsed.openAfter, "an absent `open` must default to true, not to ShareTokenURL's false")
    }

    @Test(arguments: [("true", true), ("1", true), ("false", false), ("0", false), ("nonsense", false)])
    func `honors an explicit open parameter`(value: String, expected: Bool) throws {
        let url = try #require(URL(string: "folino://open-score?token=abc&open=\(value)"))

        #expect(OpenScoreURL.parse(url)?.openAfter == expected)
    }

    @Test func `accepts a non-UUID token`() throws {
        // The contract types the token as an opaque String; requiring a UUID would reject a valid future sibling.
        let url = try #require(URL(string: "folino://open-score?token=handoff_42"))

        #expect(OpenScoreURL.parse(url)?.token == "handoff_42")
    }

    @Test(arguments: [
        "folino://import?token=5C9B7F8E-1A2B-4C3D-8E4F-6A7B8C9D0E1F",
        "vocaltuner://open-score?token=abc",
        "folino://open-score",
        "folino://open-score?token=",
        "folino://open-score?token=../../Soundfonts",
    ])
    func `rejects other hosts, schemes, and unusable tokens`(raw: String) throws {
        let url = try #require(URL(string: raw))

        #expect(OpenScoreURL.parse(url) == nil)
    }

    @Test func `leaves the share-extension route to ShareTokenURL`() throws {
        // The two routes must stay disjoint: AppBootstrap tries ShareTokenURL first and falls through to this one.
        let share = try #require(URL(string: "folino://import?token=5C9B7F8E-1A2B-4C3D-8E4F-6A7B8C9D0E1F&open=true"))
        let openScore = try #require(URL(string: "folino://open-score?token=5C9B7F8E-1A2B-4C3D-8E4F-6A7B8C9D0E1F"))

        #expect(ShareTokenURL.parse(share) != nil)
        #expect(ShareTokenURL.parse(openScore) == nil)
        #expect(OpenScoreURL.parse(share) == nil)
        #expect(OpenScoreURL.parse(openScore) != nil)
    }
}
