import Domain
import Foundation
@testable import Library
import Testing
import UtilityCore

@MainActor
struct LibraryAnalyticsTests {
    private static let base = Date(timeIntervalSince1970: 1_700_000_000)

    private static func makeItem(
        title: String = "A",
        isFavorite: Bool = false,
        tagIDs: Set<TagID> = [],
        museScoreMajorVersion: Int? = nil,
    ) -> ScoreItem {
        ScoreItem(
            title: title, composer: nil, instrumentationSummary: nil,
            localFileName: "\(title).mscx", contentHash: title,
            sizeBytes: 0, lengthBeats: 0, defaultTempoBpm: 120, primaryKey: nil,
            addedAt: base, lastOpenedAt: nil, tagIDs: tagIDs, isFavorite: isFavorite,
            museScoreMajorVersion: museScoreMajorVersion,
        )
    }

    private struct VMFixture {
        let vm: LibraryViewModel
        let repo: FakeScoreLibraryRepository
        let importer: FakeScoreFileImporter
        let analytics: SpyAnalytics
        let crashReporter: SpyCrashReporter
    }

    private static func makeVM(scoreItems: [ScoreItem] = []) -> VMFixture {
        let repo = FakeScoreLibraryRepository()
        repo.scoreItems = scoreItems
        let importer = FakeScoreFileImporter()
        let analytics = SpyAnalytics()
        let crashReporter = SpyCrashReporter()
        let vm = LibraryViewModel(
            repository: repo, importer: importer, gateway: FakeScoreFileGateway(),
            shareService: FakeScoreShareService(), metadataReader: FakeScoreMetadataReading(),
            analytics: analytics, crashReporter: crashReporter,
        )
        return VMFixture(vm: vm, repo: repo, importer: importer, analytics: analytics, crashReporter: crashReporter)
    }

    private static func makePlan(duplicates: [ScoreItem] = [], format: ScoreFormat = .mscz) -> ImportPlan {
        ImportPlan(
            sourceURL: URL(filePath: "/tmp/x.mscz"),
            stagedURL: URL(filePath: "/tmp/staged-x.mscz"),
            format: format,
            summary: ScoreFileSummary(
                title: "Imported", composer: nil, instrumentationSummary: "",
                lengthBeats: 0, defaultTempoBpm: 120, primaryKey: nil,
            ),
            contentHash: "hash", sizeBytes: 100, duplicates: duplicates,
        )
    }

    // MARK: - favorite

    @Test func `favorite from row menu logs single source`() async {
        let item = Self.makeItem(isFavorite: false)
        let f = Self.makeVM(scoreItems: [item])
        await f.vm.toggleFavorite(item, source: .scoreRowMenu)
        let event = f.analytics.event(named: "favorite_toggled")
        #expect(event?.parameters["source"] == .string("score_row_menu"))
        #expect(event?.parameters["mode"] == .string("single"))
        #expect(event?.parameters["enabled"] == .bool(true))
    }

    @Test func `bulk favorite logs bulk source`() async {
        let a = Self.makeItem(title: "A")
        let b = Self.makeItem(title: "B")
        let f = Self.makeVM(scoreItems: [a, b])
        await f.vm.bulkSetFavorite([a.id, b.id], favorite: true)
        let event = f.analytics.event(named: "favorite_toggled")
        #expect(event?.parameters["source"] == .string("bulk_edit"))
        #expect(event?.parameters["mode"] == .string("bulk"))
    }

    @Test func `failed favorite save does not log`() async {
        let item = Self.makeItem()
        let f = Self.makeVM(scoreItems: [item])
        f.repo.saveScoreItemError = .persistenceFailed(reason: "disk full")
        await f.vm.toggleFavorite(item, source: .scoreRowMenu)
        #expect(f.analytics.event(named: "favorite_toggled") == nil)
    }

    // MARK: - delete

    @Test func `delete from row menu logs single source`() async {
        let item = Self.makeItem()
        let f = Self.makeVM(scoreItems: [item])
        await f.vm.delete(item, source: .scoreRowMenu)
        let event = f.analytics.event(named: "score_deleted")
        #expect(event?.parameters["source"] == .string("score_row_menu"))
        #expect(event?.parameters["mode"] == .string("single"))
        #expect(event?.parameters["count"] == .string("1-5"))
    }

    @Test func `bulk delete logs bulk source`() async {
        let a = Self.makeItem(title: "A")
        let b = Self.makeItem(title: "B")
        let f = Self.makeVM(scoreItems: [a, b])
        await f.vm.bulkDelete([a.id, b.id])
        let event = f.analytics.event(named: "score_deleted")
        #expect(event?.parameters["source"] == .string("bulk_edit"))
        #expect(event?.parameters["mode"] == .string("bulk"))
    }

    // MARK: - import

    @Test func `successful import logs score imported`() async {
        let f = Self.makeVM()
        let plan = Self.makePlan(format: .mscz)
        f.importer.preparedPlans = [plan]
        let imported = Self.makeItem(title: "Imported", museScoreMajorVersion: 4)
        f.importer.commitFactory = { _, _ in imported }
        await f.vm.startImport(from: plan.sourceURL)
        let event = f.analytics.event(named: "score_imported")
        #expect(event?.parameters["format"] == .string("mscz"))
        #expect(event?.parameters["source"] == .string("file_picker"))
        #expect(event?.parameters["is_duplicate"] == .bool(false))
        #expect(event?.parameters["musescore_version"] == .string("4"))
    }

    @Test func `import of duplicate is flagged`() async {
        let f = Self.makeVM()
        let existing = Self.makeItem(title: "Existing")
        let plan = Self.makePlan(duplicates: [existing])
        f.importer.commitFactory = { _, _ in existing }
        await f.vm.commit(plan: plan, decision: .openExisting(existing.id))
        let event = f.analytics.event(named: "score_imported")
        #expect(event?.parameters["is_duplicate"] == .bool(true))
    }

    @Test func `import failure logs event and records non fatal`() async {
        let f = Self.makeVM()
        f.importer.prepareImportErrors = [.unsupportedFormat("xyz")]
        await f.vm.startImport(from: URL(filePath: "/tmp/x.xyz"))
        let event = f.analytics.event(named: "score_import_failed")
        #expect(event?.parameters["reason"] == .string("unsupported_format"))
        #expect(f.crashReporter.recordedErrors.count == 1)
        #expect(f.analytics.event(named: "score_imported") == nil)
    }

    // MARK: - share

    @Test func `share from row menu logs chosen format and single source`() async {
        let item = Self.makeItem()
        let f = Self.makeVM(scoreItems: [item])
        await f.vm.requestShare(item, format: .pdf)
        let event = f.analytics.event(named: "share")
        #expect(event?.parameters["method"] == .string("pdf"))
        #expect(event?.parameters["source"] == .string("score_row_menu"))
        #expect(event?.parameters["mode"] == .string("single"))
        #expect(event?.parameters["content_type"] == .string("score"))
    }

    @Test func `bulk share logs chosen format and bulk source`() async {
        let a = Self.makeItem(title: "A")
        let b = Self.makeItem(title: "B")
        let f = Self.makeVM(scoreItems: [a, b])
        await f.vm.requestBulkShare([a, b], format: .museScoreV4)
        let event = f.analytics.event(named: "share")
        #expect(event?.parameters["method"] == .string("mscz_v4"))
        #expect(event?.parameters["source"] == .string("bulk_edit"))
        #expect(event?.parameters["mode"] == .string("bulk"))
    }

    // MARK: - playlist & tag CRUD owned by the VM

    @Test func `create playlist logs source playlist`() async {
        let f = Self.makeVM()
        await f.vm.createPlaylist(name: "Recital")
        let event = f.analytics.event(named: "playlist_created")
        #expect(event?.parameters["source"] == .string("playlist"))
    }

    @Test func `create tag logs source tag`() async {
        let f = Self.makeVM()
        await f.vm.createTag(name: "Practice")
        let event = f.analytics.event(named: "tag_created")
        #expect(event?.parameters["source"] == .string("tag"))
    }

    @Test func `delete playlist logs source playlist`() async {
        let f = Self.makeVM()
        let playlist = Playlist(name: "P", orderedScoreItemIDs: [], createdAt: Self.base)
        f.repo.playlists = [playlist]
        await f.vm.deletePlaylist(playlist)
        #expect(f.analytics.event(named: "playlist_deleted")?.parameters["source"] == .string("playlist"))
    }

    @Test func `bulk add to playlist logs bulk source`() async {
        let a = Self.makeItem(title: "A")
        let b = Self.makeItem(title: "B")
        let f = Self.makeVM(scoreItems: [a, b])
        let playlist = Playlist(name: "P", orderedScoreItemIDs: [], createdAt: Self.base)
        f.repo.playlists = [playlist]
        await f.vm.bulkAddToPlaylist([a.id, b.id], to: playlist)
        let event = f.analytics.event(named: "score_added_to_playlist")
        #expect(event?.parameters["source"] == .string("bulk_edit"))
        #expect(event?.parameters["count"] == .string("1-5"))
    }

    @Test func `bulk add tags logs assignment`() async {
        let a = Self.makeItem(title: "A")
        let f = Self.makeVM(scoreItems: [a])
        let tagID = TagID()
        await f.vm.bulkAddTags([a.id], tagIDs: [tagID])
        let event = f.analytics.event(named: "tag_assigned")
        #expect(event?.parameters["source"] == .string("bulk_edit"))
    }

    @Test func `bulk add tags no change does not log`() async {
        let tagID = TagID()
        let a = Self.makeItem(title: "A", tagIDs: [tagID])
        let f = Self.makeVM(scoreItems: [a])
        await f.vm.bulkAddTags([a.id], tagIDs: [tagID])
        #expect(f.analytics.event(named: "tag_assigned") == nil)
    }

    // MARK: - sort (ScoreListViewModel)

    @Test func `select sort logs sort changed`() {
        let repo = FakeScoreLibraryRepository()
        let analytics = SpyAnalytics()
        let vm = ScoreListViewModel(source: .all, repository: repo, analytics: analytics)
        vm.selectSort(.titleAsc)
        let event = analytics.event(named: "sort_changed")
        #expect(event?.parameters["sort_order"] == .string("title"))
    }
}
