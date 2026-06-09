@testable import Domain
import Foundation
import Testing

struct SharedImportCoordinatorTests {
    /// Records calls; returns scripted per-name outcomes.
    final class FakeImporter: SharedImportFileImporting, @unchecked Sendable {
        var outcomes: [String: SharedImportFileResult] = [:]
        var seenMultiFile: [Bool] = []
        func importFile(_ file: SharedImportFile, isMultiFile: Bool) -> SharedImportFileResult {
            seenMultiFile.append(isMultiFile)
            return outcomes[file.originalName] ?? .skipped(.parseFailed)
        }
    }

    final class FakeTarget: SharedImportPlaylistTargeting, @unchecked Sendable {
        var existing: Set<String> = []
        var createReturns: String?
        var created: [String] = []
        var appended: [(ids: [String], playlist: String)] = []
        func playlistExists(id: String) -> Bool {
            existing.contains(id)
        }

        func createPlaylist(name: String) -> String? {
            guard let id = createReturns else { return nil }
            created.append(name)
            return id
        }

        func append(scoreIDs: [String], toPlaylistID id: String) {
            appended.append((scoreIDs, id))
        }
    }

    private func file(_ name: String) -> SharedImportFile {
        .init(path: "/tmp/\(name)", originalName: name)
    }

    @Test func `library only imports all no playlist`() async {
        let imp = FakeImporter()
        imp.outcomes = ["a.mscz": .imported(id: "id-a"), "b.mscz": .imported(id: "id-b")]
        let tgt = FakeTarget()
        let sut = SharedImportCoordinator(importer: imp, target: tgt)
        let r = await sut.run(files: [file("a.mscz"), file("b.mscz")], choice: .libraryOnly, openAfter: false)
        #expect(r.importedIDs == ["id-a", "id-b"])
        #expect(tgt.appended.isEmpty)
        #expect(r.openAfterID == nil)
        #expect(imp.seenMultiFile == [true, true])
    }

    @Test func `open after reports last imported`() async {
        let imp = FakeImporter()
        imp.outcomes = ["a.mscz": .imported(id: "id-a"), "b.mscz": .imported(id: "id-b")]
        let sut = SharedImportCoordinator(importer: imp, target: FakeTarget())
        let r = await sut.run(files: [file("a.mscz"), file("b.mscz")], choice: .libraryOnly, openAfter: true)
        #expect(r.openAfterID == "id-b")
    }

    @Test func `duplicate is skipped but becomes open after target`() async {
        let imp = FakeImporter()
        imp.outcomes = ["a.mscz": .duplicate(existingID: "old-1", existingTitle: "Old")]
        let sut = SharedImportCoordinator(importer: imp, target: FakeTarget())
        let r = await sut.run(files: [file("a.mscz")], choice: .libraryOnly, openAfter: true)
        #expect(r.importedIDs.isEmpty)
        #expect(r.skipped.first?.reason == .duplicate(existingID: "old-1", existingTitle: "Old"))
        #expect(r.openAfterID == "old-1")
    }

    @Test func `existing playlist appends imports`() async {
        let imp = FakeImporter()
        imp.outcomes = ["a.mscz": .imported(id: "id-a")]
        let tgt = FakeTarget()
        let pid = UUID()
        tgt.existing = [pid.uuidString]
        let sut = SharedImportCoordinator(importer: imp, target: tgt)
        let r = await sut.run(files: [file("a.mscz")], choice: .existing(PlaylistID(rawValue: pid)), openAfter: false)
        #expect(tgt.appended.count == 1)
        #expect(tgt.appended.first?.ids == ["id-a"])
        #expect(tgt.appended.first?.playlist == pid.uuidString)
        #expect(r.targetPlaylistID == pid.uuidString)
    }

    @Test func `create new playlist appends and reports created ID`() async {
        let imp = FakeImporter()
        imp.outcomes = ["a.mscz": .imported(id: "id-a")]
        let tgt = FakeTarget()
        tgt.createReturns = "new-pl"
        let sut = SharedImportCoordinator(importer: imp, target: tgt)
        let r = await sut.run(files: [file("a.mscz")], choice: .createNew(name: " My List "), openAfter: false)
        #expect(tgt.created == ["My List"]) // trimmed
        #expect(r.createdPlaylistID == "new-pl")
        #expect(tgt.appended.first?.ids == ["id-a"])
    }

    @Test func `create new failure imports nothing and reports name`() async {
        let imp = FakeImporter()
        imp.outcomes = ["a.mscz": .imported(id: "id-a")]
        let tgt = FakeTarget() // createReturns nil -> failure
        let sut = SharedImportCoordinator(importer: imp, target: tgt)
        let r = await sut.run(files: [file("a.mscz")], choice: .createNew(name: "X"), openAfter: true)
        #expect(r.importedIDs.isEmpty)
        #expect(r.playlistCreateFailureName == "X")
        #expect(r.openAfterID == nil)
        #expect(imp.seenMultiFile.isEmpty) // no import attempted
    }
}
