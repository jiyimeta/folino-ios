@testable import FolinoLibraryJNI
import Foundation
import Testing

struct LibraryAndroidStoreTests {
    /// The fixture's on-disk path (importScore takes a filesystem path).
    private func samplePath() throws -> String {
        try #require(Bundle.module.url(forResource: "sample", withExtension: "mscz")).path
    }

    @Test func `import derives title from file name and composer from metaTag`() throws {
        let store = LibraryAndroidStore()
        try store.importScore(samplePath())
        #expect(store.scores.count == 1)
        let row = try #require(store.scores.first)
        // Title is the file name (sans extension) — matches the iOS importer,
        // NOT the score's workTitle metaTag ("アイデア#0131").
        #expect(row.title == "sample")
        #expect(row.composer == "Kiichi")
        #expect(!row.id.isEmpty)
    }

    @Test func `delete removes by id`() throws {
        let store = LibraryAndroidStore()
        try store.importScore(samplePath())
        let id = try #require(store.scores.first?.id)
        store.delete(id)
        #expect(store.scores.isEmpty)
    }

    @Test func `insert re adds row`() {
        let store = LibraryAndroidStore()
        let row = ScoreRowWire(id: "x", title: "T", subtitle: "S", composer: "C")
        store.insert(row)
        #expect(store.scores == [row])
    }

    @Test func `import of nonexistent path is ignored`() {
        let store = LibraryAndroidStore()
        store.importScore("/no/such/file.mscz")
        #expect(store.scores.isEmpty)
    }
}
