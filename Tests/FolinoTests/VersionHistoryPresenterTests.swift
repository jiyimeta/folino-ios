import Domain
@testable import folino
import Foundation
import Settings
import Testing

@MainActor
struct VersionHistoryPresenterTests {
    private struct FakeLoader: VersionHistoryLoader {
        let result: Result<[VersionHistoryEntry], any Error>
        func load() throws -> [VersionHistoryEntry] {
            try result.get()
        }
    }

    private struct LoaderError: Error {}

    private static let key = "app.global.lastOpenedVersionHistory"

    private func makeDefaults() -> UserDefaults {
        let name = "test.versionHistory.\(UUID().uuidString)"
        // swiftlint:disable:next force_unwrapping
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return d
    }

    private func entries(_ versions: [AppVersion]) -> [VersionHistoryEntry] {
        versions.map { VersionHistoryEntry(version: $0, descriptions: []) }
    }

    @Test func `first install bumps key without showing sheet`() {
        let defaults = makeDefaults()
        let presenter = VersionHistoryPresenter(
            defaults: defaults,
            loader: FakeLoader(result: .success(entries([AppVersion(1, 1, 1)]))),
        )
        presenter.registerColdLaunchIfNeeded()
        #expect(presenter.isSheetPresented == false)
        #expect(defaults.string(forKey: Self.key) == AppVersion.current.rawValue)
    }

    @Test func `stored equals current does nothing`() {
        let defaults = makeDefaults()
        defaults.set(AppVersion.current.rawValue, forKey: Self.key)
        let presenter = VersionHistoryPresenter(
            defaults: defaults,
            loader: FakeLoader(result: .success(entries([AppVersion.current]))),
        )
        presenter.registerColdLaunchIfNeeded()
        #expect(presenter.isSheetPresented == false)
        #expect(defaults.string(forKey: Self.key) == AppVersion.current.rawValue)
    }

    @Test func `stored newer than current does nothing`() {
        let defaults = makeDefaults()
        let future = AppVersion(
            AppVersion.current.major + 5, AppVersion.current.minor, AppVersion.current.patch,
        )
        defaults.set(future.rawValue, forKey: Self.key)
        let presenter = VersionHistoryPresenter(
            defaults: defaults,
            loader: FakeLoader(result: .success([])),
        )
        presenter.registerColdLaunchIfNeeded()
        #expect(presenter.isSheetPresented == false)
        #expect(defaults.string(forKey: Self.key) == future.rawValue)
    }

    @Test func `loader throws leaves key untouched`() {
        let defaults = makeDefaults()
        defaults.set("0.0.1", forKey: Self.key)
        let presenter = VersionHistoryPresenter(
            defaults: defaults,
            loader: FakeLoader(result: .failure(LoaderError())),
        )
        presenter.registerColdLaunchIfNeeded()
        #expect(presenter.isSheetPresented == false)
        #expect(defaults.string(forKey: Self.key) == "0.0.1")
    }

    @Test func `loader returns no newer entries bumps key silently`() {
        let defaults = makeDefaults()
        defaults.set("0.0.1", forKey: Self.key)
        let presenter = VersionHistoryPresenter(
            defaults: defaults,
            loader: FakeLoader(result: .success(entries([AppVersion(0, 0, 1)]))),
        )
        presenter.registerColdLaunchIfNeeded()
        #expect(presenter.isSheetPresented == false)
        #expect(defaults.string(forKey: Self.key) == AppVersion.current.rawValue)
    }

    @Test func `loader returns newer entries shows sheet without bumping key`() {
        let defaults = makeDefaults()
        defaults.set("0.0.1", forKey: Self.key)
        let allEntries = entries([AppVersion.current, AppVersion(0, 0, 1)])
        let presenter = VersionHistoryPresenter(
            defaults: defaults,
            loader: FakeLoader(result: .success(allEntries)),
        )
        presenter.registerColdLaunchIfNeeded()
        #expect(presenter.isSheetPresented == true)
        #expect(presenter.sheetViewModel != nil)
        #expect(presenter.sheetViewModel?.recentChanges.map(\.version) == [AppVersion.current])
        #expect(defaults.string(forKey: Self.key) == "0.0.1")
    }

    @Test func `is idempotent across multiple calls`() {
        let defaults = makeDefaults()
        defaults.set("0.0.1", forKey: Self.key)
        let presenter = VersionHistoryPresenter(
            defaults: defaults,
            loader: FakeLoader(result: .success(entries([AppVersion.current]))),
        )
        presenter.registerColdLaunchIfNeeded()
        let firstSheetState = presenter.isSheetPresented
        presenter.isSheetPresented = false
        presenter.registerColdLaunchIfNeeded()
        #expect(firstSheetState == true)
        #expect(presenter.isSheetPresented == false)
    }

    @Test func `mark current version as seen writes key`() {
        let defaults = makeDefaults()
        let presenter = VersionHistoryPresenter(
            defaults: defaults,
            loader: FakeLoader(result: .success([])),
        )
        presenter.markCurrentVersionAsSeen()
        #expect(defaults.string(forKey: Self.key) == AppVersion.current.rawValue)
    }
}
