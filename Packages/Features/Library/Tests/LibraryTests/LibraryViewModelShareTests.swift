import Domain
import Foundation
@testable import Library
import Testing

@MainActor
struct LibraryViewModelShareTests {
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

    private static func makeVM() -> (LibraryViewModel, FakeScoreShareService) {
        let repo = FakeScoreLibraryRepository()
        let importer = FakeScoreFileImporter()
        let gateway = FakeScoreFileGateway()
        let share = FakeScoreShareService()
        let vm = LibraryViewModel(
            repository: repo, originalStore: FakeScoreOriginalStore(), importer: importer, gateway: gateway,
            shareService: share, metadataReader: FakeScoreMetadataReading(),
        )
        return (vm, share)
    }

    @Test func `request share success sets share target`() async {
        let (vm, share) = Self.makeVM()
        share.prepareShareReturnURL = URL(fileURLWithPath: "/tmp/share/T.mscz")
        await vm.requestShare(Self.makeItem(), format: .museScoreV4)
        #expect(vm.shareTarget?.urls == [URL(fileURLWithPath: "/tmp/share/T.mscz")])
        #expect(vm.currentError == nil)
        #expect(share.prepareShareCalls.count == 1)
        #expect(share.prepareShareCalls.first?.format == .museScoreV4)
    }

    @Test func `request share failure sets error alert`() async {
        let (vm, share) = Self.makeVM()
        share.prepareShareError = .scoreParseFailed(reason: "boom")
        await vm.requestShare(Self.makeItem(), format: .pdf)
        #expect(vm.shareTarget == nil)
        if case .scoreParseFailed = vm.currentError as? DomainError {} else {
            Issue.record("expected .scoreParseFailed")
        }
    }

    @Test func `is preparing share toggles around the call`() async {
        let (vm, share) = Self.makeVM()
        let observed: LockIsolated<[Bool]> = .init([])
        share.inFlightHook = { @Sendable in
            await MainActor.run { observed.withValue { $0.append(vm.isPreparingShare) } }
        }
        await vm.requestShare(Self.makeItem(), format: .midi)
        #expect(observed.value == [true])
        #expect(vm.isPreparingShare == false)
    }

    @Test func `request bulk share collects UR ls for each item`() async {
        let (vm, share) = Self.makeVM()
        share.prepareShareReturnURL = URL(fileURLWithPath: "/tmp/share/T.pdf")
        let items = [Self.makeItem(), Self.makeItem(), Self.makeItem()]

        await vm.requestBulkShare(items, format: .pdf)

        #expect(share.prepareShareCalls.count == 3)
        #expect(share.prepareShareCalls.allSatisfy { $0.format == .pdf })
        #expect(vm.shareTarget?.urls.count == 3)
        #expect(vm.currentError == nil)
    }

    @Test func `request bulk share empty is no op`() async {
        let (vm, share) = Self.makeVM()
        await vm.requestBulkShare([], format: .pdf)
        #expect(share.prepareShareCalls.isEmpty)
        #expect(vm.shareTarget == nil)
    }

    @Test func `request bulk share aborts on error`() async {
        let (vm, share) = Self.makeVM()
        share.prepareShareError = .scoreParseFailed(reason: "boom")
        await vm.requestBulkShare([Self.makeItem(), Self.makeItem()], format: .pdf)
        #expect(vm.shareTarget == nil)
        #expect(vm.currentError != nil)
    }
}

/// Tiny lock helper so the test reads `vm.isPreparingShare` from the fake's hook without a Sendable warning. Local to
/// this test file.
private final class LockIsolated<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: Value
    init(_ value: Value) {
        _value = value
    }

    var value: Value {
        lock.lock(); defer { lock.unlock() }; return _value
    }

    func withValue(_ body: (inout Value) -> Void) {
        lock.lock(); defer { lock.unlock() }; body(&_value)
    }
}
