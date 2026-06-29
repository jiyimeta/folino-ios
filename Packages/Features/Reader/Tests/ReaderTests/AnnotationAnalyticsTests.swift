import Domain
import Foundation
@testable import Reader
import Testing
import UtilityCore

@MainActor
@Suite(.serialized)
struct AnnotationAnalyticsTests {
    /// Clean up the legacy `hasUsedAnnotation` key so tests are deterministic even though the current implementation
    /// no longer writes it. Keeps the constant reference alive and the test suite isolated.
    init() {
        UserDefaults.standard.removeObject(forKey: AnalyticsStateKey.hasUsedAnnotation)
    }

    private static func makeItem() -> ScoreItem {
        ScoreItem(
            title: "Test", composer: nil, instrumentationSummary: nil,
            localFileName: "t.mid", contentHash: "h",
            sizeBytes: 0, lengthBeats: 0, defaultTempoBpm: 120, primaryKey: nil,
            addedAt: Date(timeIntervalSince1970: 0),
            lastOpenedAt: nil, tagIDs: [], isFavorite: false,
        )
    }

    private static func makeVM(analytics: SpyAnalytics) -> ReaderViewModel {
        ReaderViewModel(
            scoreItem: makeItem(),
            repository: FakeScoreLibraryRepository(),
            gateway: FakeScoreFileGateway(),
            scoresDirectory: URL(fileURLWithPath: "/dev/null"),
            analytics: analytics,
        )
    }

    private static func anchor() -> MusicalAnchor {
        MusicalAnchor(
            measureIndex: 0, tickInMeasure: 0, partIndex: 0, staffIndexInPart: 0, dxSp: 0, verticalOffsetSp: 0,
        )
    }

    /// `count` anchored strokes — only the array length matters to the commit-detection logic, so the encoded payload
    /// is just an index byte to keep the elements distinct.
    private static func strokes(_ count: Int) -> [DrawingAnchor] {
        (0 ..< count).map { DrawingAnchor(kind: .musical(anchor()), encodedDrawing: Data([UInt8($0 & 0xFF)])) }
    }

    @Test func `entering annotation mode logs annotation_started once`() {
        let spy = SpyAnalytics()
        let vm = Self.makeVM(analytics: spy)

        vm.toggleAnnotation() // enter

        #expect(vm.isAnnotating)
        #expect(spy.events.count(where: { $0.name == "annotation_started" }) == 1)
    }

    @Test func `leaving annotation mode does not log annotation_started`() {
        let spy = SpyAnalytics()
        let vm = Self.makeVM(analytics: spy)

        vm.toggleAnnotation() // enter
        vm.toggleAnnotation() // leave

        #expect(!vm.isAnnotating)
        #expect(spy.events.count(where: { $0.name == "annotation_started" }) == 1)
    }

    /// Core session-aggregation contract: entering + N strokes + exiting emits one `annotation_ended` with the correct
    /// stroke count. No per-stroke `annotation_ink_committed` events and no `has_used_annotation` user property.
    @Test func `annotation session emits annotation_ended with stroke count`() {
        let spy = SpyAnalytics()
        let vm = Self.makeVM(analytics: spy)

        vm.toggleAnnotation() // enter → resets session
        vm.recordAnnotationStroke()
        vm.recordAnnotationStroke()
        vm.recordAnnotationStroke()
        vm.toggleAnnotation() // exit → flushes session as annotation_ended

        #expect(spy.events.contains { $0.name == "annotation_started" })
        let ended = spy.events.first { $0.name == "annotation_ended" }
        #expect(ended != nil)
        #expect(ended?.parameters["ink_strokes"] == .int(3))
        #expect(!spy.events.contains { $0.name == "annotation_ink_committed" })
        #expect(spy.userProperties.isEmpty)
    }

    /// `annotation_ended` must carry a non-negative `duration_sec` parameter.
    @Test func `annotation_ended carries the session duration`() {
        let spy = SpyAnalytics()
        let vm = Self.makeVM(analytics: spy)

        vm.toggleAnnotation()
        vm.toggleAnnotation()

        let ended = spy.events.first { $0.name == "annotation_ended" }
        if case let .double(sec) = ended?.parameters["duration_sec"] {
            #expect(sec >= 0)
        } else {
            Issue.record("annotation_ended missing or wrong-typed duration_sec parameter")
        }
    }

    /// `endAnnotationSessionIfNeeded` must fire at most once per session: a second call without a new
    /// session is a no-op.
    @Test func `endAnnotationSessionIfNeeded is idempotent`() {
        let spy = SpyAnalytics()
        let vm = Self.makeVM(analytics: spy)

        vm.toggleAnnotation()
        vm.endAnnotationSessionIfNeeded() // first call: flushes
        vm.endAnnotationSessionIfNeeded() // second call: no-op

        #expect(spy.events.count(where: { $0.name == "annotation_ended" }) == 1)
    }

    /// Stroke count fed through `annotationDrawingsDidChange` (the real canvas path) is reflected in
    /// `annotation_ended`.
    /// Re-anchoring (same count) and erasing (lower count) must not increment the counter.
    @Test func `stroke count from annotationDrawingsDidChange is reflected in annotation_ended`() {
        let spy = SpyAnalytics()
        let vm = Self.makeVM(analytics: spy)

        vm.toggleAnnotation()
        vm.annotationDrawingsDidChange(Self.strokes(1)) // 0 → 1: genuine commit → stroke count 1
        vm.annotationDrawingsDidChange(Self.strokes(1)) // reflow re-anchor, same count: no commit
        vm.annotationDrawingsDidChange(Self.strokes(0)) // erase: no commit
        vm.toggleAnnotation() // exit → flush

        let ended = spy.events.first { $0.name == "annotation_ended" }
        #expect(ended?.parameters["ink_strokes"] == .int(1))
        #expect(!spy.events.contains { $0.name == "annotation_ink_committed" })
    }
}
