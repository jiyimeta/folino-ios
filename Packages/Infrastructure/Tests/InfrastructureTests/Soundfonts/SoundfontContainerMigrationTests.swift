import Foundation
@testable import Soundfonts
import Testing

struct SoundfontContainerMigrationTests {
    private let fm = FileManager.default
    private let name = "MuseScore_General.sf2"
    private let minBytes: Int64 = 100 // small threshold for fast tests

    private func tempDir() -> URL {
        let url = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? fm.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func write(_ dir: URL, bytes: Int) {
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        try? Data(count: bytes).write(to: dir.appendingPathComponent(name))
    }

    private func exists(_ dir: URL) -> Bool {
        fm.fileExists(atPath: dir.appendingPathComponent(name).path)
    }

    @Test func `folino first moves legacy into shared`() {
        let shared = tempDir(), legacy = tempDir()
        write(legacy, bytes: 200)
        SoundfontContainerMigration().reconcile(
            fileName: name, sharedDirectory: shared, legacyDirectory: legacy, minimumValidByteSize: minBytes,
        )
        #expect(exists(shared))
        #expect(!exists(legacy))
    }

    @Test func `vocal tuner first deletes redundant legacy`() {
        let shared = tempDir(), legacy = tempDir()
        write(shared, bytes: 200) // sibling already populated shared
        write(legacy, bytes: 200) // existing Folino user still has the private copy
        SoundfontContainerMigration().reconcile(
            fileName: name, sharedDirectory: shared, legacyDirectory: legacy, minimumValidByteSize: minBytes,
        )
        #expect(exists(shared))
        #expect(!exists(legacy)) // redundant legacy removed
    }

    @Test func `fresh install no legacy noop`() {
        let shared = tempDir(), legacy = tempDir()
        SoundfontContainerMigration().reconcile(
            fileName: name, sharedDirectory: shared, legacyDirectory: legacy, minimumValidByteSize: minBytes,
        )
        #expect(!exists(shared))
        #expect(!exists(legacy))
    }

    @Test func `partial legacy below threshold not moved not deleted`() {
        let shared = tempDir(), legacy = tempDir()
        write(legacy, bytes: 10) // truncated
        SoundfontContainerMigration().reconcile(
            fileName: name, sharedDirectory: shared, legacyDirectory: legacy, minimumValidByteSize: minBytes,
        )
        #expect(!exists(shared))
        #expect(exists(legacy)) // left for re-download
    }

    @Test func `equal dirs noop`() {
        let dir = tempDir()
        write(dir, bytes: 200)
        SoundfontContainerMigration().reconcile(
            fileName: name, sharedDirectory: dir, legacyDirectory: dir, minimumValidByteSize: minBytes,
        )
        #expect(exists(dir))
    }

    @Test func `idempotent second run noop`() {
        let shared = tempDir(), legacy = tempDir()
        write(legacy, bytes: 200)
        let m = SoundfontContainerMigration()
        m.reconcile(fileName: name, sharedDirectory: shared, legacyDirectory: legacy, minimumValidByteSize: minBytes)
        m.reconcile(fileName: name, sharedDirectory: shared, legacyDirectory: legacy, minimumValidByteSize: minBytes)
        #expect(exists(shared))
        #expect(!exists(legacy))
    }
}
