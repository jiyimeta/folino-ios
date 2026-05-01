@testable import Domain
import Foundation
import Testing

@Suite struct SoundfontPatchTests {
    @Test func identityIsBankAndProgram() {
        let patch = SoundfontPatch(
            bank: 0, program: 4,
            localFileName: "000_004.sf2",
            sizeBytes: 1_600_000,
            downloadedAt: Date(timeIntervalSince1970: 1_700_000_000),
            lastUsedAt: Date(timeIntervalSince1970: 1_700_001_000)
        )
        #expect(patch.id == SoundfontPatchKey(bank: 0, program: 4))
    }

    @Test func roundTripsThroughCodable() throws {
        let patch = SoundfontPatch(
            bank: 128, program: 0,
            localFileName: "128_000_lite.sf2",
            sizeBytes: 1_800_000,
            downloadedAt: Date(timeIntervalSince1970: 1_700_000_000),
            lastUsedAt: Date(timeIntervalSince1970: 1_700_001_000)
        )
        let data = try JSONEncoder().encode(patch)
        let decoded = try JSONDecoder().decode(SoundfontPatch.self, from: data)
        #expect(decoded == patch)
    }

    @Test func bundledFlagDefaultsFalse() {
        let patch = SoundfontPatch(
            bank: 0, program: 4,
            localFileName: "x.sf2", sizeBytes: 0,
            downloadedAt: Date(), lastUsedAt: Date()
        )
        #expect(patch.isBundled == false)
    }

    @Test func bundledFlagPropagates() {
        let patch = SoundfontPatch(
            bank: 0, program: 4,
            localFileName: "x.sf2", sizeBytes: 0,
            downloadedAt: Date(), lastUsedAt: Date(),
            isBundled: true
        )
        #expect(patch.isBundled == true)
    }
}
