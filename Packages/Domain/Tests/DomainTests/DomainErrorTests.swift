@testable import Domain
import Foundation
import Testing

@Suite struct DomainErrorTests {
    @Test func conformsToError() {
        let error: any Error = DomainError.scoreFileNotFound(name: "x.mscz")
        _ = error
    }

    @Test func equatableCases() {
        let notFoundA1 = DomainError.scoreFileNotFound(name: "a")
        let notFoundA2 = DomainError.scoreFileNotFound(name: "a")
        #expect(notFoundA1 == notFoundA2)
        #expect(DomainError.scoreFileNotFound(name: "a") != DomainError.scoreFileNotFound(name: "b"))
        let key = SoundfontPatchKey(bank: 0, program: 4)
        let download1 = DomainError.soundfontDownloadFailed(key)
        let download2 = DomainError.soundfontDownloadFailed(key)
        #expect(download1 == download2)
    }

    @Test func providesLocalizedDescription() {
        let error = DomainError.unsupportedFormat("rtf")
        #expect(!error.localizedDescription.isEmpty)
    }
}
