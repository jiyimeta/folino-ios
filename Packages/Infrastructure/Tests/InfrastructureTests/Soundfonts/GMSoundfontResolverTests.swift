import Domain
import Foundation
@testable import Soundfonts
import Testing

struct GMSoundfontResolverTests {
    @Test func `soundfontURL is always nil — engine consults defaultGMSoundfontURL`() throws {
        let resolver = try GMSoundfontResolver(
            provider: StubProvider(museScoreGeneralFileURL: nil),
            bundle: makeBundleStub(),
        )
        #expect(resolver.soundfontURL(forBank: 0, program: 0, isDrums: false) == nil)
        #expect(resolver.soundfontURL(forBank: 0, program: 0, isDrums: true) == nil)
    }

    @Test func `defaultGMSoundfontURL prefers downloaded high-quality preset when present`() throws {
        let downloaded = URL(filePath: "/tmp/MuseScore_General.sf2")
        let resolver = try GMSoundfontResolver(
            provider: StubProvider(museScoreGeneralFileURL: downloaded),
            bundle: makeBundleStub(),
        )
        #expect(resolver.defaultGMSoundfontURL == downloaded)
    }

    @Test func `defaultGMSoundfontURL falls back to bundled lightweight preset when nothing downloaded`() throws {
        let bundle = try makeBundleStub()
        let resolver = GMSoundfontResolver(
            provider: StubProvider(museScoreGeneralFileURL: nil),
            bundle: bundle,
        )
        let url = resolver.defaultGMSoundfontURL
        #expect(url?.lastPathComponent == "GeneralUser-GS.sf2")
    }
}

private struct StubProvider: MuseScoreGeneralProvider {
    let museScoreGeneralFileURL: URL?
    var isOptedIn: Bool {
        true
    }

    var isDownloaded: Bool {
        museScoreGeneralFileURL != nil
    }

    var currentPreset: SoundfontPreset {
        isDownloaded ? .highQuality : .lightweight
    }

    var museScoreGeneralFileURLSync: URL? {
        museScoreGeneralFileURL
    }

    func setOptedIn(_: Bool) {}
    func downloadStateStream() -> AsyncStream<SoundfontDownloadState> {
        AsyncStream { _ in }
    }

    func startDownloadIfNeeded() {}
    func startDownloadAllowingCellular() {}
    func cancelDownload() {}
    func deleteDownloaded() {}
}

/// Builds a fake `Bundle` containing only `Soundfonts/GeneralUser-GS.sf2` so the resolver's bundle lookup has a target.
private func makeBundleStub() throws -> Bundle {
    let tmp = FileManager.default.temporaryDirectory.appending(
        path: "GMSoundfontResolverTests-\(UUID().uuidString).bundle",
    )
    let soundfontsDir = tmp.appending(path: "Soundfonts")
    try FileManager.default.createDirectory(at: soundfontsDir, withIntermediateDirectories: true)
    try Data([0xFF]).write(to: soundfontsDir.appending(path: "GeneralUser-GS.sf2"))
    guard let bundle = Bundle(url: tmp) else { throw NSError(domain: "bundle", code: 1) }
    return bundle
}
