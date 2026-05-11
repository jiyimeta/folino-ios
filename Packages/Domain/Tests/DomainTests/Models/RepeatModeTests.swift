import Domain
import Foundation
import Testing

struct RepeatModeTests {
    @Test func `cycle advances off to all to ab and back to off`() {
        #expect(RepeatMode.off.next == .loopAll)
        #expect(RepeatMode.loopAll.next == .abLoop)
        #expect(RepeatMode.abLoop.next == .off)
    }

    @Test func `round trips through JSON`() throws {
        for mode in [RepeatMode.off, .loopAll, .abLoop] {
            let data = try JSONEncoder().encode(mode)
            let decoded = try JSONDecoder().decode(RepeatMode.self, from: data)
            #expect(decoded == mode)
        }
    }
}
