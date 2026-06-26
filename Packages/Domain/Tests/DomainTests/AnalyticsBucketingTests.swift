@testable import Domain
import Testing

struct AnalyticsBucketingTests {
    @Test(arguments: [
        (0, "0"), (1, "1-5"), (5, "1-5"), (6, "6-20"), (20, "6-20"),
        (21, "21-50"), (50, "21-50"), (51, "51+"), (1000, "51+"),
    ])
    func `buckets counts`(_ input: Int, _ expected: String) {
        #expect(countBucket(input) == expected)
    }

    @Test func `source wire values are snake case`() {
        #expect(AnalyticsSource.scoreRowMenu.rawValue == "score_row_menu")
        #expect(AnalyticsSource.searchResult.rawValue == "search_result")
    }
}
