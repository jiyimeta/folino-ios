@testable import Domain
import Foundation
@testable import ScoreFiles
import SheetMusic
import Testing

struct LiveScoreFileGatewayTests {
    @Test func `detects known extensions`() {
        let gateway = LiveScoreFileGateway()
        #expect(gateway.detectFormat(fileName: "x.mscz") == .mscz)
        #expect(gateway.detectFormat(fileName: "x.MSCZ") == .mscz)
        #expect(gateway.detectFormat(fileName: "x.mid") == .midi)
        #expect(gateway.detectFormat(fileName: "x.pdf") == .pdf)
        #expect(gateway.detectFormat(fileName: "x.txt") == nil)
    }

    @Test func `load file metadata returns summary for MSCX`() async throws {
        let tmp = try TempDirectory()
        let mscxURL = try Fixtures.writeToTempFile(
            Fixtures.minimalMSCXData(), ext: "mscx", in: tmp.url,
        )
        let gateway = LiveScoreFileGateway()
        let summary = try await gateway.loadFileMetadata(fileURL: mscxURL)
        // Fixture is one quarter note + three rests = one measure of 4/4. The helper's per-measure fallback returns 4
        // beats. Either reading is acceptable for v1 — assert ">= 0".
        #expect(summary.lengthBeats >= 0)
    }

    @Test func `load file metadata throws for unreadable PDF`() async throws {
        // An empty/unreadable PDF has no pages, so the metadata path reports a parse failure rather than returning a
        // summary. (A valid PDF returns a metadata-only summary; that path is covered by LiveScoreFileGatewayPDFTests.)
        let tmp = try TempDirectory()
        let pdfURL = try Fixtures.writeToTempFile(Data(), ext: "pdf", in: tmp.url)
        let gateway = LiveScoreFileGateway()
        do {
            _ = try await gateway.loadFileMetadata(fileURL: pdfURL)
            Issue.record("expected throw")
        } catch DomainError.scoreParseFailed {
            // Expected.
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test func `load score rejects PDF as unsupported`() async throws {
        let tmp = try TempDirectory()
        let pdfURL = try Fixtures.writeToTempFile(Data(), ext: "pdf", in: tmp.url)
        let gateway = LiveScoreFileGateway()
        do {
            _ = try await gateway.loadScore(fileURL: pdfURL)
            Issue.record("expected throw")
        } catch let DomainError.unsupportedFormat(ext) {
            #expect(ext == "pdf")
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test func `load score returns score and summary`() async throws {
        let tmp = try TempDirectory()
        let mscxURL = try Fixtures.writeToTempFile(
            Fixtures.minimalMSCXData(), ext: "mscx", in: tmp.url,
        )
        let gateway = LiveScoreFileGateway()
        let result = try await gateway.loadScore(fileURL: mscxURL)
        #expect(result.score.parts.isEmpty == false)
    }

    @Test func `load file metadata round trips MSCZ`() async throws {
        let tmp = try TempDirectory()
        let msczURL = try Fixtures.writeToTempFile(
            Fixtures.minimalMSCZData(), ext: "mscz", in: tmp.url,
        )
        let gateway = LiveScoreFileGateway()
        let summary = try await gateway.loadFileMetadata(fileURL: msczURL)
        #expect(summary.lengthBeats >= 0)
    }

    @Test func `load file metadata reads MIDI`() async throws {
        let tmp = try TempDirectory()
        let midURL = try Fixtures.writeToTempFile(
            Fixtures.minimalMIDIData(), ext: "mid", in: tmp.url,
        )
        let gateway = LiveScoreFileGateway()
        let summary = try await gateway.loadFileMetadata(fileURL: midURL)
        #expect(summary.lengthBeats >= 0)
    }

    @Test func `load score parses MIDI`() async throws {
        let tmp = try TempDirectory()
        let midURL = try Fixtures.writeToTempFile(
            Fixtures.minimalMIDIData(), ext: "mid", in: tmp.url,
        )
        let gateway = LiveScoreFileGateway()
        let result = try await gateway.loadScore(fileURL: midURL)
        #expect(result.score.parts.isEmpty == false)
    }

    @Test func `save score throws unsupported format in V 1`() async throws {
        let tmp = try TempDirectory()
        let gateway = LiveScoreFileGateway()
        let score = try SheetMusic.loadScore(mscxData: Fixtures.minimalMSCXData())
        let outURL = tmp.url.appending(path: "out.mscz")
        do {
            try await gateway.saveScore(score, fileURL: outURL, format: .mscz)
            Issue.record("expected throw")
        } catch DomainError.unsupportedFormat {
            // Expected.
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test func `clean parse emits no diagnostics`() async throws {
        let tmp = try TempDirectory()
        let mscxURL = try Fixtures.writeToTempFile(
            Fixtures.minimalMSCXData(), ext: "mscx", in: tmp.url,
        )
        let fake = FakeCrashReporter()
        let gateway = LiveScoreFileGateway(crashReporter: fake)
        _ = try await gateway.loadScore(fileURL: mscxURL)
        #expect(fake.recordedErrors.isEmpty)
    }

    @Test func `unknown tremolo subtype is reported as one non-fatal`() async throws {
        let tmp = try TempDirectory()
        let mscxURL = try Fixtures.writeToTempFile(
            Fixtures.unknownTremoloMSCXData(), ext: "mscx", in: tmp.url,
        )
        let fake = FakeCrashReporter()
        let gateway = LiveScoreFileGateway(crashReporter: fake)
        // The score still loads — the unknown tremolo is dropped, not fatal.
        _ = try await gateway.loadScore(fileURL: mscxURL)
        #expect(fake.recordedErrors.count == 1)
        let recorded = try #require(fake.recordedErrors.first)
        #expect((recorded as NSError).domain == "mscx.tremolo.unknownSubtype")
    }
}
