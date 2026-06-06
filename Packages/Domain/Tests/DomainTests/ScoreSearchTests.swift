@testable import Domain
import Foundation
import Testing

struct ScoreSearchTests {
    @Test func `empty query matches everything`() {
        #expect(ScoreSearch.matches(title: "Sonata", composer: "Mozart", query: ""))
        #expect(ScoreSearch.matches(title: "Sonata", composer: nil, query: "   "))
    }

    @Test func `matches title substring case insensitively`() {
        #expect(ScoreSearch.matches(title: "Moonlight Sonata", composer: nil, query: "sonata"))
        #expect(ScoreSearch.matches(title: "Moonlight Sonata", composer: nil, query: "MOON"))
    }

    @Test func `matches composer substring`() {
        #expect(ScoreSearch.matches(title: "Prelude", composer: "Chopin", query: "chop"))
    }

    @Test func `matches diacritic insensitively`() {
        #expect(ScoreSearch.matches(title: "Étude Op.10", composer: nil, query: "etude"))
    }

    @Test func `no match returns false`() {
        #expect(!ScoreSearch.matches(title: "Prelude", composer: "Chopin", query: "mozart"))
    }

    @Test func `nil composer does not match and does not crash`() {
        #expect(!ScoreSearch.matches(title: "Prelude", composer: nil, query: "chopin"))
    }

    @Test func `query is trimmed before matching`() {
        #expect(ScoreSearch.matches(title: "Sonata", composer: nil, query: "  sonata  "))
    }
}
