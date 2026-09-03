import Foundation
@testable import ScoreUI
import Testing

/// Ⅷ §7: on macOS a single exported file gets a save panel seeded with its own name — extension included, since
/// `defaultFilename` is the only mechanism that carries an extension through to the saved file; several files get a
/// folder chooser instead, because a save panel cannot name more than one destination.
struct ScoreExportPlanTests {
    @Test func `one url exports as a single file, keeping its full name including extension`() {
        let plan = ScoreExportPlan(urls: [URL(fileURLWithPath: "/tmp/Now is the time.mscz")])
        #expect(plan == .single(
            url: URL(fileURLWithPath: "/tmp/Now is the time.mscz"),
            defaultFilename: "Now is the time.mscz",
        ))
    }

    @Test func `several urls export into a chosen folder`() {
        let urls = [
            URL(fileURLWithPath: "/tmp/a.mscz"),
            URL(fileURLWithPath: "/tmp/b.pdf"),
        ]
        #expect(ScoreExportPlan(urls: urls) == .multiple(urls: urls))
    }

    @Test func `an empty target exports nothing`() {
        #expect(ScoreExportPlan(urls: []) == .nothing)
    }

    @Test func `a dotted filename keeps every component, including the extension`() {
        let plan = ScoreExportPlan(urls: [URL(fileURLWithPath: "/tmp/BWV 1007.no.1.mscz")])
        #expect(plan == .single(
            url: URL(fileURLWithPath: "/tmp/BWV 1007.no.1.mscz"),
            defaultFilename: "BWV 1007.no.1.mscz",
        ))
    }

    @Test func `the default filename never drops the extension`() {
        let plan = ScoreExportPlan(urls: [URL(fileURLWithPath: "/tmp/Sonata.mscz")])
        guard case let .single(_, defaultFilename) = plan else {
            Issue.record("expected a single-file plan")
            return
        }
        #expect(defaultFilename.hasSuffix(".mscz"))
    }
}
