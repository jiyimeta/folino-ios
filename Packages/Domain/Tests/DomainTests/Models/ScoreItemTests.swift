@testable import Domain
import Foundation
import Testing

struct ScoreItemTests {
    private func sample() -> ScoreItem {
        ScoreItem(
            id: ScoreItemID(),
            title: "Prelude in C",
            composer: "J. S. Bach",
            instrumentationSummary: "Piano",
            localFileName: "prelude.mscz",
            contentHash: "0000000000000000000000000000000000000000000000000000000000000000",
            sizeBytes: 8192,
            lengthBeats: 56,
            defaultTempoBpm: 72,
            primaryKey: "C major",
            addedAt: Date(timeIntervalSince1970: 1_700_000_000),
            lastOpenedAt: nil,
            tagIDs: [],
            isFavorite: false,
        )
    }

    @Test func `round trips through codable`() throws {
        let item = sample()
        let data = try JSONEncoder().encode(item)
        let decoded = try JSONDecoder().decode(ScoreItem.self, from: data)
        #expect(decoded == item)
    }

    @Test func `can hold optional metadata`() {
        let item = ScoreItem(
            id: ScoreItemID(),
            title: "Untitled",
            composer: nil,
            instrumentationSummary: nil,
            localFileName: "x.mid",
            contentHash: "deadbeef",
            sizeBytes: 0,
            lengthBeats: 0,
            defaultTempoBpm: 120,
            primaryKey: nil,
            addedAt: Date(),
            lastOpenedAt: nil,
            tagIDs: [],
            isFavorite: false,
        )
        #expect(item.composer == nil)
        #expect(item.primaryKey == nil)
    }

    @Test func `conforms to identifiable`() {
        let item = sample()
        let _: ScoreItemID = item.id
    }

    @Test func `tag I ds are order independent`() {
        let t1 = TagID()
        let t2 = TagID()
        let base = sample()
        let a = base.with(tagIDs: [t1, t2])
        let b = base.with(tagIDs: [t2, t1])
        #expect(a == b)
    }

    @Test func `content hash is carried through codable`() throws {
        let item = sample()
        let data = try JSONEncoder().encode(item)
        let decoded = try JSONDecoder().decode(ScoreItem.self, from: data)
        #expect(decoded.contentHash == item.contentHash)
    }

    @Test func `new credit fields round-trip through Codable`() throws {
        let item = ScoreItem(
            title: "Sonata",
            composer: "Beethoven",
            arranger: "Liszt",
            lyricist: "Schiller",
            copyright: "© 1824",
            instrumentationSummary: nil,
            localFileName: "x.mscx",
            contentHash: "h",
            sizeBytes: 1,
            lengthBeats: 0,
            defaultTempoBpm: 120,
            primaryKey: nil,
            addedAt: Date(timeIntervalSince1970: 0),
            lastOpenedAt: nil,
            tagIDs: [],
            isFavorite: false,
        )
        let data = try JSONEncoder().encode(item)
        let decoded = try JSONDecoder().decode(ScoreItem.self, from: data)
        #expect(decoded.arranger == "Liszt")
        #expect(decoded.lyricist == "Schiller")
        #expect(decoded.copyright == "© 1824")
    }

    @Test func `decoding legacy JSON without credit fields yields nil`() throws {
        // A ScoreItem encoded before the new fields existed has no arranger/lyricist/copyright keys.
        let json =
            """
            {"id":{"rawValue":"00000000-0000-0000-0000-000000000000"},"title":"Old",\
            "localFileName":"o.mscx","contentHash":"h","sizeBytes":1,"lengthBeats":0,\
            "defaultTempoBpm":120,"addedAt":0,"tagIDs":[],"isFavorite":false}
            """
        let decoded = try JSONDecoder().decode(ScoreItem.self, from: Data(json.utf8))
        #expect(decoded.arranger == nil)
        #expect(decoded.lyricist == nil)
        #expect(decoded.copyright == nil)
    }
}

extension ScoreItem {
    fileprivate func with(tagIDs: Set<TagID>) -> ScoreItem {
        ScoreItem(
            id: id,
            title: title,
            composer: composer,
            instrumentationSummary: instrumentationSummary,
            localFileName: localFileName,
            contentHash: contentHash,
            sizeBytes: sizeBytes,
            lengthBeats: lengthBeats,
            defaultTempoBpm: defaultTempoBpm,
            primaryKey: primaryKey,
            addedAt: addedAt,
            lastOpenedAt: lastOpenedAt,
            tagIDs: tagIDs,
            isFavorite: isFavorite,
        )
    }
}
