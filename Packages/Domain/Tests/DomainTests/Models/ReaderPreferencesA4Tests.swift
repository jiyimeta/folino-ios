@testable import Domain
import Foundation
import Testing

struct ReaderPreferencesA4Tests {
    @Test func `a 4 reference hz round trips and defaults nil`() throws {
        var prefs = ReaderPreferences(scoreItemID: .init(), staffSize: 16, hiddenStaves: [])
        #expect(prefs.a4ReferenceHz == nil)
        prefs.a4ReferenceHz = 432
        let data = try JSONEncoder().encode(prefs)
        #expect(try JSONDecoder().decode(ReaderPreferences.self, from: data).a4ReferenceHz == 432)
    }
}
