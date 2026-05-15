import Foundation
@testable import ImportExport
import Testing

@Suite("ShareTokenURL")
struct ShareTokenURLTests {
    @Test func `parses valid import URL`() throws {
        let token = UUID()
        let url = try #require(URL(string: "folino://import?token=\(token.uuidString)&open=true"))
        let parsed = ShareTokenURL.parse(url)
        #expect(parsed?.token == token)
        #expect(parsed?.openAfter == true)
    }

    @Test func `parses open false`() throws {
        let token = UUID()
        let url = try #require(URL(string: "folino://import?token=\(token.uuidString)&open=false"))
        let parsed = ShareTokenURL.parse(url)
        #expect(parsed?.openAfter == false)
    }

    @Test func `defaults open after to false when missing`() throws {
        let token = UUID()
        let url = try #require(URL(string: "folino://import?token=\(token.uuidString)"))
        let parsed = ShareTokenURL.parse(url)
        #expect(parsed?.openAfter == false)
    }

    @Test func `rejects wrong scheme`() throws {
        let url = try #require(URL(string: "file:///tmp/foo.mscz"))
        #expect(ShareTokenURL.parse(url) == nil)
    }

    @Test func `rejects wrong host`() throws {
        let url = try #require(URL(string: "folino://export?token=\(UUID().uuidString)"))
        #expect(ShareTokenURL.parse(url) == nil)
    }

    @Test func `rejects missing token`() throws {
        let url = try #require(URL(string: "folino://import?open=true"))
        #expect(ShareTokenURL.parse(url) == nil)
    }

    @Test func `rejects malformed token`() throws {
        let url = try #require(URL(string: "folino://import?token=not-a-uuid&open=true"))
        #expect(ShareTokenURL.parse(url) == nil)
    }

    @Test func builds() {
        let token = UUID()
        let url = ShareTokenURL.build(token: token, openAfter: true)
        #expect(url.scheme == "folino")
        #expect(url.host == "import")
        let parsed = ShareTokenURL.parse(url)
        #expect(parsed?.token == token)
        #expect(parsed?.openAfter == true)
    }
}
