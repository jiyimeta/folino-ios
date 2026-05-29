import Foundation
@testable import ScoreFiles
import Testing

struct ScoreParseDiagnosticNSErrorTests {
    @Test func `maps code to domain and message to localized description`() {
        let diagnostic = ScoreParseDiagnostic(
            severity: .warning,
            code: "mscx.tremolo.unknownSubtype",
            message: "Tremolo unknown <subtype> r64",
            location: "measure 12, voice 1, Tremolo",
        )
        let error = diagnostic.asNSError()
        #expect(error.domain == "mscx.tremolo.unknownSubtype")
        #expect(error.localizedDescription == "Tremolo unknown <subtype> r64")
        #expect(error.userInfo["diagnosticCode"] as? String == "mscx.tremolo.unknownSubtype")
        #expect(error.userInfo["severity"] as? String == "warning")
        #expect(error.userInfo["location"] as? String == "measure 12, voice 1, Tremolo")
    }

    @Test func `nil location becomes empty string and info severity maps`() {
        let diagnostic = ScoreParseDiagnostic(severity: .info, code: "x", message: "m", location: nil)
        let error = diagnostic.asNSError()
        #expect((error.userInfo["location"] as? String)?.isEmpty == true)
        #expect(error.userInfo["severity"] as? String == "info")
    }

    @Test func `does not leak filename or content keys`() {
        let diagnostic = ScoreParseDiagnostic(severity: .warning, code: "x", message: "m", location: nil)
        let keys = Set(diagnostic.asNSError().userInfo.keys)
        #expect(keys.contains("filename") == false)
        #expect(keys.contains("path") == false)
        #expect(keys.contains("content") == false)
    }
}
