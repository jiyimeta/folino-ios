import Testing
@testable import UtilityCore

struct AnalyticsEventTests {
    @Test func `event stores name and parameters`() {
        let event = AnalyticsEvent(name: "score_imported", parameters: ["format": .string("mscz")])
        #expect(event.name == "score_imported")
        #expect(event.parameters["format"] == .string("mscz"))
    }

    @Test func `user property stores wire name`() {
        let property = AnalyticsUserProperty(name: "layout_mode")
        #expect(property.name == "layout_mode")
    }
}
