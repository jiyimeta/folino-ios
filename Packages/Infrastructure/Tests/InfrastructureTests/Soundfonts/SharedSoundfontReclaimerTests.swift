import Foundation
@testable import Soundfonts
import Testing

private final class FakeChecker: InstalledAppChecking, @unchecked Sendable {
    var installed: Set<String>
    init(_ installed: Set<String>) {
        self.installed = installed
    }

    func isInstalled(urlScheme: String) -> Bool {
        installed.contains(urlScheme)
    }
}

struct SharedSoundfontReclaimerTests {
    private let fm = FileManager.default
    private let name = "MuseScore_General.sf2"
    private let minBytes: Int64 = 100
    private let sibling = SiblingApp(bundleId: "com.KeyNumber.VocalTuner", urlScheme: "vocaltuner")

    private func dir() -> URL {
        let url = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? fm.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func writeSoundfont(_ d: URL, bytes: Int) {
        try? Data(count: bytes).write(to: d.appendingPathComponent(name))
    }

    private func sfExists(_ d: URL) -> Bool {
        fm.fileExists(atPath: d.appendingPathComponent(name).path)
    }

    private func markerExists(_ d: URL, _ id: String) -> Bool {
        fm.fileExists(atPath: d.appendingPathComponent("consumers").appendingPathComponent(id).path)
    }

    private func make(_ d: URL, checker: FakeChecker) -> SharedSoundfontReclaimer {
        SharedSoundfontReclaimer(
            fileManager: fm, soundfontsDirectory: d, soundfontFileName: name, minimumValidByteSize: minBytes,
            ownBundleId: "com.KeyNumber.Folino", ownDisplayName: "folino",
            siblings: [sibling], installedChecker: checker,
        )
    }

    @Test func `sync own marker writes when opted in removes when out`() {
        let d = dir(); let r = make(d, checker: FakeChecker([]))
        r.syncOwnMarker(isOptedIn: true)
        #expect(markerExists(d, "com.KeyNumber.Folino"))
        let markerURL = d.appendingPathComponent("consumers").appendingPathComponent("com.KeyNumber.Folino")
        let body = try? JSONSerialization.jsonObject(with: Data(contentsOf: markerURL)) as? [String: String]
        #expect(body?["displayName"] == "folino")
        r.syncOwnMarker(isOptedIn: false)
        #expect(!markerExists(d, "com.KeyNumber.Folino"))
    }

    @Test func `reclaim opted out no sibling deletes file`() {
        let d = dir(); writeSoundfont(d, bytes: 200)
        make(d, checker: FakeChecker([])).reclaimIfUnused(isOptedIn: false)
        #expect(!sfExists(d))
    }

    @Test func `reclaim opted in keeps file`() {
        let d = dir(); writeSoundfont(d, bytes: 200)
        make(d, checker: FakeChecker([])).reclaimIfUnused(isOptedIn: true)
        #expect(sfExists(d))
    }

    @Test func `reclaim opted out installed sibling opted in keeps file`() {
        let d = dir(); writeSoundfont(d, bytes: 200)
        try? fm.createDirectory(at: d.appendingPathComponent("consumers"), withIntermediateDirectories: true)
        try? Data("{}".utf8).write(to: d.appendingPathComponent("consumers").appendingPathComponent(sibling.bundleId))
        make(d, checker: FakeChecker([sibling.urlScheme])).reclaimIfUnused(isOptedIn: false)
        #expect(sfExists(d))
    }

    @Test func `reclaim opted out sibling marker but not installed deletes and prunes`() {
        let d = dir(); writeSoundfont(d, bytes: 200)
        try? fm.createDirectory(at: d.appendingPathComponent("consumers"), withIntermediateDirectories: true)
        try? Data("{}".utf8).write(to: d.appendingPathComponent("consumers").appendingPathComponent(sibling.bundleId))
        make(d, checker: FakeChecker([])).reclaimIfUnused(isOptedIn: false) // sibling NOT installed
        #expect(!sfExists(d))
        #expect(!markerExists(d, sibling.bundleId)) // stale marker pruned
    }

    @Test func `sibling in use display name returns published name when installed and marker present`() {
        let d = dir()
        try? fm.createDirectory(at: d.appendingPathComponent("consumers"), withIntermediateDirectories: true)
        try? Data(#"{"displayName":"VocalTuner"}"#.utf8)
            .write(to: d.appendingPathComponent("consumers").appendingPathComponent(sibling.bundleId))
        let name = make(d, checker: FakeChecker([sibling.urlScheme])).siblingInUseDisplayName()
        #expect(name == "VocalTuner")
    }

    @Test func `sibling in use display name nil when not installed`() {
        let d = dir()
        try? fm.createDirectory(at: d.appendingPathComponent("consumers"), withIntermediateDirectories: true)
        try? Data(#"{"displayName":"VocalTuner"}"#.utf8)
            .write(to: d.appendingPathComponent("consumers").appendingPathComponent(sibling.bundleId))
        #expect(make(d, checker: FakeChecker([])).siblingInUseDisplayName() == nil)
    }

    @Test func `sibling in use display name prefers hardcoded name over empty published marker`() {
        // Some shipped sibling builds publish an empty `displayName` in their marker; the note must fall back to our
        // own hardcoded brand name rather than render blank.
        let d = dir()
        let named = SiblingApp(bundleId: sibling.bundleId, urlScheme: sibling.urlScheme, displayName: "VocalTuner")
        try? fm.createDirectory(at: d.appendingPathComponent("consumers"), withIntermediateDirectories: true)
        try? Data(#"{"displayName":""}"#.utf8)
            .write(to: d.appendingPathComponent("consumers").appendingPathComponent(sibling.bundleId))
        let r = SharedSoundfontReclaimer(
            fileManager: fm, soundfontsDirectory: d, soundfontFileName: name, minimumValidByteSize: minBytes,
            ownBundleId: "com.KeyNumber.Folino", ownDisplayName: "folino",
            siblings: [named], installedChecker: FakeChecker([named.urlScheme]),
        )
        #expect(r.siblingInUseDisplayName() == "VocalTuner")
    }
}
