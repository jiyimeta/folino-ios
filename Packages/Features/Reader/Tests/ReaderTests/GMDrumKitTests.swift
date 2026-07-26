import Domain
@testable import Reader
import Testing

struct GMDrumKitTests {
    @Test func `catalog matches SF2 split release`() {
        let programs = GMDrumKit.all.map(\.program)
        let expected: [UInt8] = [
            0, 1, 2, 3, 4, 5, 6, 7,
            8, 9, 10, 11, 12, 13, 14, 15,
            16, 17, 18, 19,
            24, 25,
            32, 33, 34, 35, 36,
            40, 41, 42,
            48,
            56, 57, 58, 59, 95, 96,
        ]
        #expect(programs == expected)
    }

    @Test func `every family has at least one kit`() {
        for family in GMDrumKit.Family.allCases {
            #expect(!family.kits.isEmpty, "family \(family.rawValue) is empty")
        }
    }

    @Test func `kit(for:) roundtrips known programs`() {
        for kit in GMDrumKit.all {
            #expect(GMDrumKit.kit(for: kit.program) == kit)
        }
    }

    @Test func `kit(for:) returns nil for unknown program`() {
        #expect(GMDrumKit.kit(for: 99) == nil)
        #expect(GMDrumKit.kit(for: 127) == nil)
    }

    @Test func `family rawValues group kits as published`() {
        #expect(GMDrumKit.Family.standard.kits.count == 8)
        #expect(GMDrumKit.Family.room.kits.count == 8)
        #expect(GMDrumKit.Family.power.kits.count == 4)
        #expect(GMDrumKit.Family.electronic.kits.count == 1)
        #expect(GMDrumKit.Family.tr808.kits.count == 1)
        #expect(GMDrumKit.Family.jazz.kits.count == 5)
        #expect(GMDrumKit.Family.brush.kits.count == 3)
        #expect(GMDrumKit.Family.orchestra.kits.count == 1)
        #expect(GMDrumKit.Family.marching.kits.count == 6)
    }
}
