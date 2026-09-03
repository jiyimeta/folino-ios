import Foundation
@testable import ScoreUI
import Testing

/// Ⅷ §7: on macOS a single exported file gets a save panel seeded with its own name; several files get a folder
/// chooser instead, because a save panel cannot name more than one destination.
struct ScoreExportPlanTests {
    @Test func `one url exports as a single file, keeping its name`() {
        let plan = ScoreExportPlan(urls: [URL(fileURLWithPath: "/tmp/Now is the time.mscz")])
        #expect(plan == .single(
            url: URL(fileURLWithPath: "/tmp/Now is the time.mscz"),
            defaultFilename: "Now is the time",
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

    @Test func `a dotted filename keeps every component but the last`() {
        let plan = ScoreExportPlan(urls: [URL(fileURLWithPath: "/tmp/BWV 1007.no.1.mscz")])
        #expect(plan == .single(
            url: URL(fileURLWithPath: "/tmp/BWV 1007.no.1.mscz"),
            defaultFilename: "BWV 1007.no.1",
        ))
    }
}
