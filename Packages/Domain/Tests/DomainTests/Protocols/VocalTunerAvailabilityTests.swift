import Domain
import Foundation
import Testing

struct VocalTunerAvailabilityTests {
    @Test func `not installed when the scheme cannot be opened`() {
        let result = VocalTunerAvailability.resolve(
            canOpenVocalTuner: false,
            capabilities: VocalTunerCapabilities(protocolVersion: 1, vocalTunerAppVersion: "3.4.1"),
        )
        #expect(result == .notInstalled)
    }

    @Test func `legacy when installed without a capability stamp`() {
        let result = VocalTunerAvailability.resolve(canOpenVocalTuner: true, capabilities: nil)
        #expect(result == .installedLegacy)
    }

    @Test func `legacy when the stamp advertises a lower protocol version`() {
        let result = VocalTunerAvailability.resolve(
            canOpenVocalTuner: true,
            capabilities: VocalTunerCapabilities(protocolVersion: 0, vocalTunerAppVersion: "3.4.1"),
        )
        #expect(result == .installedLegacy)
    }

    @Test func `handoff capable when the stamp meets the required version`() {
        let result = VocalTunerAvailability.resolve(
            canOpenVocalTuner: true,
            capabilities: VocalTunerCapabilities(protocolVersion: 1, vocalTunerAppVersion: "3.4.1"),
        )
        #expect(result == .installedHandoffCapable)
    }

    @Test func `handoff capable when the stamp is ahead of the required version`() {
        let result = VocalTunerAvailability.resolve(
            canOpenVocalTuner: true,
            capabilities: VocalTunerCapabilities(protocolVersion: 7, vocalTunerAppVersion: "4.0.0"),
        )
        #expect(result == .installedHandoffCapable)
    }

    @Test func `capabilities decode from the stamp JSON`() throws {
        let json = Data(#"{"protocolVersion":1,"vocalTunerAppVersion":"3.4.1"}"#.utf8)
        let decoded = try JSONDecoder().decode(VocalTunerCapabilities.self, from: json)
        #expect(decoded == VocalTunerCapabilities(protocolVersion: 1, vocalTunerAppVersion: "3.4.1"))
    }
}
