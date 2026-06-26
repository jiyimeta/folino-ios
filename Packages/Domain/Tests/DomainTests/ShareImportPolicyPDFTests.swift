@testable import Domain
import Testing

struct ShareImportPolicyPDFTests {
    @Test func `accepts PDF`() {
        #expect(ShareImportPolicy.isAccepted(filename: "score.pdf"))
        #expect(ShareImportPolicy.isAccepted(filename: "SCORE.PDF"))
    }
}
