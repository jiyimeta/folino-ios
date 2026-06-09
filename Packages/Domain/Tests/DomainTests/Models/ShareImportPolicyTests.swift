@testable import Domain
import Testing

struct ShareImportPolicyTests {
    @Test func `accepts known extensions case insensitively`() {
        #expect(ShareImportPolicy.isAccepted(filename: "song.mscz"))
        #expect(ShareImportPolicy.isAccepted(filename: "SONG.MSCZ"))
        #expect(ShareImportPolicy.isAccepted(filename: "a.musicxml"))
        #expect(ShareImportPolicy.isAccepted(filename: "b.MID"))
        #expect(ShareImportPolicy.isAccepted(filename: "c.midi"))
    }

    @Test func `rejects unknown or missing extensions`() {
        #expect(!ShareImportPolicy.isAccepted(filename: "doc.pdf"))
        #expect(!ShareImportPolicy.isAccepted(filename: "noext"))
        #expect(!ShareImportPolicy.isAccepted(filename: ""))
    }
}
