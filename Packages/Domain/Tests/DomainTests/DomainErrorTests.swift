@testable import Domain
import Foundation
import Testing

struct DomainErrorTests {
    @Test func `conforms to error`() {
        let error: any Error = DomainError.scoreFileNotFound(name: "x.mscz")
        _ = error
    }

    @Test func `equatable cases`() {
        let notFoundA1 = DomainError.scoreFileNotFound(name: "a")
        let notFoundA2 = DomainError.scoreFileNotFound(name: "a")
        #expect(notFoundA1 == notFoundA2)
        #expect(DomainError.scoreFileNotFound(name: "a") != DomainError.scoreFileNotFound(name: "b"))
    }

    @Test func `provides localized description`() {
        let error = DomainError.unsupportedFormat("rtf")
        #expect(!error.localizedDescription.isEmpty)
    }
}
