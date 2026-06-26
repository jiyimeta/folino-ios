import Foundation
import PDFKit
@testable import Reader
import Testing

@MainActor struct PDFPageProviderTests {
    private func provider(window: Int = 2) throws -> PDFPageProvider {
        let url = try #require(Bundle.module.url(forResource: "sample", withExtension: "pdf"))
        let document = try #require(PDFDocument(url: url))
        return PDFPageProvider(document: document, windowRadius: window)
    }

    @Test func `renders page image`() throws {
        let p = try provider()
        let img = p.image(pageIndex: 0, targetScale: 1)
        #expect(img != nil)
    }

    @Test func `higher scale yields larger bitmap`() throws {
        let p = try provider()
        let small = try #require(p.image(pageIndex: 0, targetScale: 1))
        let big = try #require(p.image(pageIndex: 0, targetScale: 2))
        #expect(big.width > small.width)
    }

    @Test func `reports page count`() throws {
        #expect(try provider().pageCount >= 1)
    }
}
