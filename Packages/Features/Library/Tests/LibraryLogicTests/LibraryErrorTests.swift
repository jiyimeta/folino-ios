import Domain
import LibraryLogic
import Testing

struct LibraryErrorTests {
    @Test
    func `wraps domain error`() {
        let err = LibraryError.from(DomainError.unsupportedFormat("xml"))
        #expect(err == .domain(.unsupportedFormat("xml")))
    }

    @Test
    func `wraps unknown error as underlying`() {
        struct Boom: Error {}
        let err = LibraryError.from(Boom())
        if case .underlying = err {
            // ok
        } else {
            Issue.record("expected .underlying, got \(err)")
        }
    }
}
