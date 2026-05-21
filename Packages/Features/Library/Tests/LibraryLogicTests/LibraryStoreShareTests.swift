import Domain
import Foundation
import LibraryLogic
import Testing

@MainActor
struct LibraryStoreShareTests {
    private static let base = Date(timeIntervalSince1970: 1_700_000_000)

    private static func makeItem() -> ScoreItem {
        ScoreItem(
            title: "T", composer: nil, instrumentationSummary: nil,
            localFileName: "T.mscz", contentHash: "h",
            sizeBytes: 0, lengthBeats: 0, defaultTempoBpm: 120,
            primaryKey: nil, addedAt: base, lastOpenedAt: nil,
            tagIDs: [], isFavorite: false,
        )
    }

    private static func makeStore() -> (LibraryStore, FakeScoreShareService) {
        let repo = FakeScoreLibraryRepository()
        let importer = FakeScoreFileImporter()
        let gateway = FakeScoreFileGateway()
        let share = FakeScoreShareService()
        let store = LibraryStore(
            repository: repo, importer: importer, gateway: gateway, shareService: share,
        )
        return (store, share)
    }

    @Test func `request share success sets share target`() async {
        let (store, share) = Self.makeStore()
        share.prepareShareReturnURL = URL(fileURLWithPath: "/tmp/share/T.mscz")
        await store.requestShare(Self.makeItem(), format: .museScoreV4)
        #expect(store.shareTarget?.urls == [URL(fileURLWithPath: "/tmp/share/T.mscz")])
        #expect(store.currentError == nil)
        #expect(share.prepareShareCalls.count == 1)
        #expect(share.prepareShareCalls.first?.format == .museScoreV4)
    }

    @Test func `request share failure sets currentError`() async {
        let (store, share) = Self.makeStore()
        share.prepareShareError = .scoreParseFailed(reason: "boom")
        await store.requestShare(Self.makeItem(), format: .pdf)
        #expect(store.shareTarget == nil)
        #expect(store.currentError == .domain(.scoreParseFailed(reason: "boom")))
    }

    @Test func `is preparing share toggles around the call`() async {
        let (store, share) = Self.makeStore()
        let observed: LockIsolated<[Bool]> = .init([])
        share.inFlightHook = { @Sendable in
            await MainActor.run { observed.withValue { $0.append(store.isPreparingShare) } }
        }
        await store.requestShare(Self.makeItem(), format: .midi)
        #expect(observed.value == [true])
        #expect(store.isPreparingShare == false)
    }

    @Test func `request bulk share collects URLs for each item`() async {
        let (store, share) = Self.makeStore()
        share.prepareShareReturnURL = URL(fileURLWithPath: "/tmp/share/T.pdf")
        let items = [Self.makeItem(), Self.makeItem(), Self.makeItem()]

        await store.requestBulkShare(items, format: .pdf)

        #expect(share.prepareShareCalls.count == 3)
        #expect(share.prepareShareCalls.allSatisfy { $0.format == .pdf })
        #expect(store.shareTarget?.urls.count == 3)
        #expect(store.currentError == nil)
    }

    @Test func `request bulk share empty is no op`() async {
        let (store, share) = Self.makeStore()
        await store.requestBulkShare([], format: .pdf)
        #expect(share.prepareShareCalls.isEmpty)
        #expect(store.shareTarget == nil)
    }

    @Test func `request bulk share aborts on error`() async {
        let (store, share) = Self.makeStore()
        share.prepareShareError = .scoreParseFailed(reason: "boom")
        await store.requestBulkShare([Self.makeItem(), Self.makeItem()], format: .pdf)
        #expect(store.shareTarget == nil)
        #expect(store.currentError != nil)
    }
}

/// Tiny lock helper so the test reads `store.isPreparingShare` from the fake's hook without a Sendable warning.
private final class LockIsolated<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: Value

    init(_ value: Value) {
        _value = value
    }

    var value: Value {
        lock.lock()
        defer { lock.unlock() }
        return _value
    }

    func withValue(_ body: (inout Value) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        body(&_value)
    }
}
