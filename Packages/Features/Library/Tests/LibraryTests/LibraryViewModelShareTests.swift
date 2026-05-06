import Domain
import Foundation
@testable import Library
import Testing

@Suite @MainActor
struct LibraryViewModelShareTests {
    private static let base = Date(timeIntervalSince1970: 1_700_000_000)

    private static func makeItem() -> ScoreItem {
        ScoreItem(
            title: "T", composer: nil, instrumentationSummary: nil,
            localFileName: "T.mscz", contentHash: "h",
            sizeBytes: 0, lengthBeats: 0, defaultTempoBpm: 120,
            primaryKey: nil, addedAt: base, lastOpenedAt: nil,
            tagIDs: [], isFavorite: false
        )
    }

    private static func makeVM() -> (LibraryViewModel, FakeScoreShareService) {
        let repo = FakeScoreLibraryRepository()
        let importer = FakeScoreFileImporter()
        let gateway = FakeScoreFileGateway()
        let share = FakeScoreShareService()
        let vm = LibraryViewModel(
            repository: repo, importer: importer, gateway: gateway, shareService: share
        )
        return (vm, share)
    }

    @Test func requestShareSuccessSetsShareTarget() async {
        let (vm, share) = Self.makeVM()
        share.prepareShareReturnURL = URL(fileURLWithPath: "/tmp/share/T.mscz")
        await vm.requestShare(Self.makeItem(), format: .sourceFormat)
        #expect(vm.shareTarget?.url.path == "/tmp/share/T.mscz")
        #expect(vm.errorAlertMessage == nil)
        #expect(share.prepareShareCalls.count == 1)
        #expect(share.prepareShareCalls.first?.format == .sourceFormat)
    }

    @Test func requestShareFailureSetsErrorAlert() async {
        let (vm, share) = Self.makeVM()
        share.prepareShareError = .scoreParseFailed(reason: "boom")
        await vm.requestShare(Self.makeItem(), format: .pdf)
        #expect(vm.shareTarget == nil)
        #expect(vm.errorAlertMessage == "This file looks corrupted or isn't a valid score.")
    }

    @Test func isPreparingShareTogglesAroundTheCall() async {
        let (vm, share) = Self.makeVM()
        let observed: LockIsolated<[Bool]> = .init([])
        share.inFlightHook = { @Sendable in
            await MainActor.run { observed.withValue { $0.append(vm.isPreparingShare) } }
        }
        await vm.requestShare(Self.makeItem(), format: .midi)
        #expect(observed.value == [true])
        #expect(vm.isPreparingShare == false)
    }
}

/// Tiny lock helper so the test reads `vm.isPreparingShare` from the
/// fake's hook without a Sendable warning. Local to this test file.
private final class LockIsolated<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: Value
    init(_ value: Value) { _value = value }
    var value: Value { lock.lock(); defer { lock.unlock() }; return _value }
    func withValue(_ body: (inout Value) -> Void) {
        lock.lock(); defer { lock.unlock() }; body(&_value)
    }
}
