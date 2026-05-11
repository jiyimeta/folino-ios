@testable import Domain
import Testing

struct AppVersionTests {
    @Test func `init from valid dotted string`() {
        #expect(AppVersion("1.2.3") == AppVersion(1, 2, 3))
        #expect(AppVersion("0.0.0") == .zero)
        #expect(AppVersion("10.20.30") == AppVersion(10, 20, 30))
    }

    @Test(arguments: ["", "1", "1.2", "1.2.3.4", "1.2.x", "abc", "1..2"])
    func `init from invalid string returns nil`(_ raw: String) {
        #expect(AppVersion(raw) == nil)
    }

    @Test func comparable() {
        let table: [(AppVersion, AppVersion)] = [
            (AppVersion(1, 0, 0), AppVersion(1, 0, 1)),
            (AppVersion(1, 0, 1), AppVersion(1, 1, 0)),
            (AppVersion(1, 1, 0), AppVersion(2, 0, 0)),
            (AppVersion(1, 9, 9), AppVersion(2, 0, 0)),
        ]
        for (lhs, rhs) in table {
            #expect(lhs < rhs)
            #expect(rhs > lhs)
            #expect(lhs != rhs)
        }
    }

    @Test func `raw value round trip`() {
        let cases = [AppVersion.zero, AppVersion(1, 2, 3), AppVersion(0, 0, 1), AppVersion(99, 99, 99)]
        for v in cases {
            #expect(AppVersion(rawValue: v.rawValue) == v)
            #expect(v.description == v.rawValue)
        }
    }

    @Test func `zero raw value`() {
        #expect(AppVersion.zero.rawValue == "0.0.0")
        #expect(AppVersion(rawValue: "0.0.0") == .zero)
    }
}
