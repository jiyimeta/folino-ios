import CryptoKit
import Domain
@testable import Editor
import Foundation
import Testing

@MainActor
@Suite("EditorViewModel persistence")
struct EditorViewModelPersistenceTests {
    // MARK: - saveDestination (pure)

    @Test func `mscz source saves in place`() {
        let dir = URL(filePath: "/tmp/scores", directoryHint: .isDirectory)
        var item = EditorFixtures.sampleItem()
        item.localFileName = "ABC.mscz"
        let destination = EditorViewModel.saveDestination(for: item, scoresDirectory: dir)
        #expect(destination.url == dir.appending(path: "ABC.mscz"))
        #expect(destination.format == .mscz)
        #expect(destination.isSiblingCopy == false)
    }

    @Test func `mscx source saves in place`() {
        let dir = URL(filePath: "/tmp/scores", directoryHint: .isDirectory)
        var item = EditorFixtures.sampleItem()
        item.localFileName = "ABC.mscx"
        let destination = EditorViewModel.saveDestination(for: item, scoresDirectory: dir)
        #expect(destination.url == dir.appending(path: "ABC.mscx"))
        #expect(destination.format == .mscx)
        #expect(destination.isSiblingCopy == false)
    }

    @Test func `musicxml source saves as a sibling mscz`() {
        let dir = URL(filePath: "/tmp/scores", directoryHint: .isDirectory)
        var item = EditorFixtures.sampleItem()
        item.localFileName = "ABC.musicxml"
        let destination = EditorViewModel.saveDestination(for: item, scoresDirectory: dir)
        #expect(destination.url == dir.appending(path: "ABC.mscz"))
        #expect(destination.format == .mscz)
        #expect(destination.isSiblingCopy == true)
    }

    @Test func `midi source saves as a sibling mscz`() {
        let dir = URL(filePath: "/tmp/scores", directoryHint: .isDirectory)
        var item = EditorFixtures.sampleItem()
        item.localFileName = "ABC.mid"
        let destination = EditorViewModel.saveDestination(for: item, scoresDirectory: dir)
        #expect(destination.url == dir.appending(path: "ABC.mscz"))
        #expect(destination.format == .mscz)
        #expect(destination.isSiblingCopy == true)
    }

    // MARK: - EditorFileFacts.hashAndSize

    @Test func `hashAndSize matches the importer's hex digest format`() throws {
        let bytes = Data([0x01, 0x02, 0x03, 0x04, 0x05])
        let expectedHash = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        let url = FileManager.default.temporaryDirectory
            .appending(path: "editor-file-facts-\(UUID().uuidString).bin")
        try bytes.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let facts = try EditorFileFacts.hashAndSize(of: url)
        #expect(facts.sizeBytes == 5)
        #expect(facts.contentHash == expectedHash)
    }

    // MARK: - performSave via flushPendingSave

    private func makeTempScoresDirectory() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "editor-persistence-\(UUID().uuidString)", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static let savedBytesHash = SHA256.hash(data: Data("saved".utf8))
        .map { String(format: "%02x", $0) }.joined()

    @Test func `flush saves through the gateway and refreshes the row`() async throws {
        let dir = makeTempScoresDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let gateway = FakeScoreFileGateway()
        let repository = FakeScoreLibraryRepository()
        let item = EditorFixtures.sampleItem()
        let vm = EditorViewModel(
            scoreItem: item,
            scoresDirectory: dir,
            gateway: gateway,
            repository: repository,
            originalStore: FakeScoreOriginalStore(),
            historyStore: NoopScoreEditHistoryStore(),
            playback: nil,
        )
        vm.beginSession(score: EditorFixtures.fourQuarterRests())
        vm.apply(.inputNote(at: EditorFixtures.restID(element: 1), pitch: 60, tpc: 14, duration: nil))

        await vm.flushPendingSave()

        #expect(gateway.savedCalls.count == 1)
        let call = try #require(gateway.savedCalls.first)
        #expect(call.1 == dir.appending(path: "score.mscz"))
        #expect(call.2 == .mscz)

        #expect(repository.savedScoreItems.count == 1)
        let saved = try #require(repository.savedScoreItems.first)
        #expect(saved.id == item.id)
        #expect(saved.contentHash == Self.savedBytesHash)
        #expect(vm.scoreItem.contentHash == Self.savedBytesHash)
    }

    @Test func `sibling copy updates localFileName and sets the one-time flag`() async throws {
        let dir = makeTempScoresDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let gateway = FakeScoreFileGateway()
        let repository = FakeScoreLibraryRepository()
        var item = EditorFixtures.sampleItem()
        item.localFileName = "song.musicxml"
        let vm = EditorViewModel(
            scoreItem: item,
            scoresDirectory: dir,
            gateway: gateway,
            repository: repository,
            originalStore: FakeScoreOriginalStore(),
            historyStore: NoopScoreEditHistoryStore(),
            playback: nil,
        )
        vm.beginSession(score: EditorFixtures.fourQuarterRests())
        vm.apply(.inputNote(at: EditorFixtures.restID(element: 1), pitch: 60, tpc: 14, duration: nil))

        #expect(vm.didSaveAsSiblingMSCZ == false)
        await vm.flushPendingSave()

        let call = try #require(gateway.savedCalls.first)
        #expect(call.1 == dir.appending(path: "song.mscz"))
        #expect(call.2 == .mscz)

        let saved = try #require(repository.savedScoreItems.first)
        #expect(saved.localFileName == "song.mscz")
        #expect(vm.scoreItem.localFileName == "song.mscz")
        #expect(vm.didSaveAsSiblingMSCZ == true)
    }

    @Test func `debounce coalesces three edits into one save`() async {
        let dir = makeTempScoresDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let gateway = FakeScoreFileGateway()
        let repository = FakeScoreLibraryRepository()
        let vm = EditorViewModel(
            scoreItem: EditorFixtures.sampleItem(),
            scoresDirectory: dir,
            gateway: gateway,
            repository: repository,
            originalStore: FakeScoreOriginalStore(),
            historyStore: NoopScoreEditHistoryStore(),
            playback: nil,
        )
        vm.beginSession(score: EditorFixtures.fourQuarterRests())
        vm.apply(.inputNote(at: EditorFixtures.restID(element: 1), pitch: 60, tpc: 14, duration: nil))
        vm.apply(.inputNote(at: EditorFixtures.restID(element: 2), pitch: 62, tpc: 16, duration: nil))
        vm.apply(.inputNote(at: EditorFixtures.restID(element: 3), pitch: 64, tpc: 18, duration: nil))

        await vm.flushPendingSave()

        #expect(gateway.savedCalls.count == 1)
        #expect(repository.savedScoreItems.count == 1)
    }

    @Test func `clean session flush saves nothing`() async {
        let dir = makeTempScoresDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let gateway = FakeScoreFileGateway()
        let repository = FakeScoreLibraryRepository()
        let vm = EditorViewModel(
            scoreItem: EditorFixtures.sampleItem(),
            scoresDirectory: dir,
            gateway: gateway,
            repository: repository,
            originalStore: FakeScoreOriginalStore(),
            historyStore: NoopScoreEditHistoryStore(),
            playback: nil,
        )
        vm.beginSession(score: EditorFixtures.fourQuarterRests())

        await vm.flushPendingSave()

        #expect(gateway.savedCalls.isEmpty)
        #expect(repository.savedScoreItems.isEmpty)
    }

    // MARK: - Original capture (Task 4)

    @Test func `the first save captures the original before writing`() async throws {
        let dir = makeTempScoresDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let gateway = FakeScoreFileGateway()
        let repository = FakeScoreLibraryRepository()
        let originalStore = FakeScoreOriginalStore()
        let vm = EditorViewModel(
            scoreItem: EditorFixtures.sampleItem(),
            scoresDirectory: dir,
            gateway: gateway,
            repository: repository,
            originalStore: originalStore,
            historyStore: NoopScoreEditHistoryStore(),
            playback: nil,
        )
        vm.beginSession(score: EditorFixtures.fourQuarterRests())
        vm.apply(.inputNote(at: EditorFixtures.restID(element: 1), pitch: 60, tpc: 14, duration: nil))

        await vm.flushPendingSave()

        #expect(originalStore.captureCalls.count == 1)
        let saved = try #require(repository.savedScoreItems.first)
        #expect(saved.originalFileName == "score.original.mscz")
        #expect(saved.originalContentHash == "captured-hash")
        #expect(vm.scoreItem.originalFileName == "score.original.mscz")
        #expect(vm.hasCapturedOriginal == true)
    }

    @Test func `the capture is asked for before the gateway writes`() async {
        let dir = makeTempScoresDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        // A shared log both fakes append to: the only way to prove ONE fake's call happened before the OTHER's,
        // rather than merely happening before `scoreItem` was reassigned — which passes identically whether the
        // capture ran before or after the write, and would not catch a regression that swapped the two calls.
        let eventLog = FakeEventLog()
        let gateway = FakeScoreFileGateway()
        gateway.eventLog = eventLog
        let repository = FakeScoreLibraryRepository()
        let originalStore = FakeScoreOriginalStore()
        originalStore.eventLog = eventLog
        let vm = EditorViewModel(
            scoreItem: EditorFixtures.sampleItem(),
            scoresDirectory: dir,
            gateway: gateway,
            repository: repository,
            originalStore: originalStore,
            historyStore: NoopScoreEditHistoryStore(),
            playback: nil,
        )
        vm.beginSession(score: EditorFixtures.fourQuarterRests())
        vm.apply(.inputNote(at: EditorFixtures.restID(element: 1), pitch: 60, tpc: 14, duration: nil))

        await vm.flushPendingSave()

        #expect(eventLog.events == ["capture", "save"])
    }

    @Test func `a clean flush never asks for a capture`() async {
        let dir = makeTempScoresDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let originalStore = FakeScoreOriginalStore()
        let vm = EditorViewModel(
            scoreItem: EditorFixtures.sampleItem(),
            scoresDirectory: dir,
            gateway: FakeScoreFileGateway(),
            repository: FakeScoreLibraryRepository(),
            originalStore: originalStore,
            historyStore: NoopScoreEditHistoryStore(),
            playback: nil,
        )
        vm.beginSession(score: EditorFixtures.fourQuarterRests())

        await vm.flushPendingSave()

        #expect(originalStore.captureCalls.isEmpty)
    }
}
