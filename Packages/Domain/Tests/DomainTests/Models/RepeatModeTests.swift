import Domain
import Foundation
import Testing

@Suite
struct RepeatModeTests {
    @Test func cycleAdvancesOffToAllToAbAndBackToOff() {
        #expect(RepeatMode.off.next == .loopAll)
        #expect(RepeatMode.loopAll.next == .abLoop)
        #expect(RepeatMode.abLoop.next == .off)
    }

    @Test func roundTripsThroughJSON() throws {
        for mode in [RepeatMode.off, .loopAll, .abLoop] {
            let data = try JSONEncoder().encode(mode)
            let decoded = try JSONDecoder().decode(RepeatMode.self, from: data)
            #expect(decoded == mode)
        }
    }
}
