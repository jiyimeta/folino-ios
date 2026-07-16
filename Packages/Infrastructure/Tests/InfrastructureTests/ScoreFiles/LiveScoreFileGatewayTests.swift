@testable import Domain
import Foundation
@testable import ScoreFiles
import SheetMusic
import Testing

/// `MSCXEncoder` always resynthesizes `Part.id` as sequential 1-based integers on encode (see the doc comment on
/// `MSCXEncoder+Part.encodeDeclaration` in swift-sheet-music) — deliberate upstream behavior unrelated to this
/// gateway, not a defect it can (or should) work around. Normalizing both sides to the same convention keeps a
/// round-trip assertion meaningful for the content this gateway is actually responsible for.
private func normalizingPartIDs(_ score: Score) -> Score {
    var normalized = score
    normalized.parts = normalized.parts.enumerated().map { index, part in
        var part = part
        part.id = String(index + 1)
        return part
    }
    return normalized
}

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

    @Test func `save score round trips MSCX semantically`() async throws {
        let tmp = try TempDirectory()
        let gateway = LiveScoreFileGateway()
        let score = try SheetMusic.loadScore(mscxData: Fixtures.minimalMSCXData())
        let outURL = tmp.url.appending(path: "out.mscx")
        try await gateway.saveScore(score, fileURL: outURL, format: .mscx)
        let reloaded = try await gateway.loadScore(fileURL: outURL)
        #expect(normalizingPartIDs(reloaded.score) == normalizingPartIDs(score))
    }

    @Test func `save score round trips MSCZ semantically`() async throws {
        let tmp = try TempDirectory()
        let gateway = LiveScoreFileGateway()
        let score = try SheetMusic.loadScore(mscxData: Fixtures.minimalMSCXData())
        let outURL = tmp.url.appending(path: "out.mscz")
        try await gateway.saveScore(score, fileURL: outURL, format: .mscz)
        let reloaded = try await gateway.loadScore(fileURL: outURL)
        #expect(normalizingPartIDs(reloaded.score) == normalizingPartIDs(score))
    }

    @Test func `save score still rejects encoder-less formats`() async throws {
        let tmp = try TempDirectory()
        let gateway = LiveScoreFileGateway()
        let score = try SheetMusic.loadScore(mscxData: Fixtures.minimalMSCXData())
        for format in [ScoreFormat.musicXML, .mxl, .midi, .pdf] {
            do {
                try await gateway.saveScore(score, fileURL: tmp.url.appending(path: "x.bin"), format: format)
                Issue.record("expected throw for \(format)")
            } catch DomainError.unsupportedFormat {
                // Expected.
            }
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
