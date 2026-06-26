import Domain
import Foundation
@testable import Reader
import Testing
import UtilityCore

@MainActor
@Suite(.serialized)
struct AnnotationAnalyticsTests {
    /// `has_used_annotation` is a one-shot flag persisted in `UserDefaults.standard`; clear it before each test so the
    /// first-commit behaviour is deterministic and the flag never leaks from one test into the next.
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
        (0 ..< count).map { DrawingAnchor(anchor: anchor(), encodedDrawing: Data([UInt8($0 & 0xFF)])) }
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

    @Test func `committing a stroke logs annotation_ink_committed`() {
        let spy = SpyAnalytics()
        let vm = Self.makeVM(analytics: spy)

        vm.annotationDrawingsDidChange(Self.strokes(1)) // 0 -> 1

        #expect(spy.event(named: "annotation_ink_committed") != nil)
    }

    @Test func `first ink commit sets hasUsedAnnotation flag and has_used_annotation property`() {
        let spy = SpyAnalytics()
        let vm = Self.makeVM(analytics: spy)

        vm.annotationDrawingsDidChange(Self.strokes(1))

        #expect(UserDefaults.standard.bool(forKey: AnalyticsStateKey.hasUsedAnnotation))
        let props = spy.userProperties.filter { $0.property == .hasUsedAnnotation }
        #expect(props.count == 1)
        #expect(props.first?.value == "true")
    }

    @Test func `every commit logs the event but the property is set only on the first`() {
        let spy = SpyAnalytics()
        let vm = Self.makeVM(analytics: spy)

        vm.annotationDrawingsDidChange(Self.strokes(1)) // 0 -> 1, commit #1
        vm.annotationDrawingsDidChange(Self.strokes(2)) // 1 -> 2, commit #2

        #expect(spy.events.count(where: { $0.name == "annotation_ink_committed" }) == 2)
        #expect(spy.userProperties.count(where: { $0.property == .hasUsedAnnotation }) == 1)
    }

    @Test func `re-anchoring or erasing does not log a spurious commit`() {
        let spy = SpyAnalytics()
        let vm = Self.makeVM(analytics: spy)

        vm.annotationDrawingsDidChange(Self.strokes(1)) // 0 -> 1: genuine commit
        vm.annotationDrawingsDidChange(Self.strokes(1)) // reflow re-anchor, same count: no commit
        vm.annotationDrawingsDidChange(Self.strokes(0)) // erase, lower count: no commit

        #expect(spy.events.count(where: { $0.name == "annotation_ink_committed" }) == 1)
    }
}
