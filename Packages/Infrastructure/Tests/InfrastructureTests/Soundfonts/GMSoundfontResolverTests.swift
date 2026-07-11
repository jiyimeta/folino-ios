import Domain
import Foundation
import Observation
@testable import Soundfonts
import Testing

@MainActor
struct GMSoundfontResolverTests {
    @Test func `soundfontURL is always nil — engine consults defaultGMSoundfontURL`() throws {
        let resolver = try GMSoundfontResolver(
            provider: StubProvider(downloadedURL: nil),
            bundle: makeBundleStub(),
        )
        #expect(resolver.soundfontURL(forBank: 0, program: 0, isDrums: false) == nil)
        #expect(resolver.soundfontURL(forBank: 0, program: 0, isDrums: true) == nil)
    }

    @Test func `defaultGMSoundfontURL prefers downloaded high-quality preset when present`() throws {
        let downloaded = URL(filePath: "/tmp/MuseScore_General.sf2")
        let resolver = try GMSoundfontResolver(
            provider: StubProvider(downloadedURL: downloaded),
            bundle: makeBundleStub(),
        )
        #expect(resolver.defaultGMSoundfontURL == downloaded)
    }

    @Test func `defaultGMSoundfontURL falls back to bundled lightweight preset when nothing downloaded`() throws {
        let bundle = try makeBundleStub()
        let resolver = GMSoundfontResolver(
            provider: StubProvider(downloadedURL: nil),
            bundle: bundle,
        )
        let url = resolver.defaultGMSoundfontURL
        #expect(url?.lastPathComponent == "GeneralUser-GS.sf2")
    }

    @Test func `defaultGMSoundfontURL falls back to lightweight when opted out even if file present`() throws {
        // An opted-in sibling keeps the shared high-quality file on disk, but this app is opted out — playback must
        // use the bundled lightweight preset, not the shared file that only lingers for the sibling's sake.
        let downloaded = URL(filePath: "/tmp/MuseScore_General.sf2")
        let resolver = try GMSoundfontResolver(
            provider: StubProvider(downloadedURL: downloaded, optedIn: false),
            bundle: makeBundleStub(),
        )
        #expect(resolver.defaultGMSoundfontURL?.lastPathComponent == "GeneralUser-GS.sf2")
    }
}

@MainActor
@Observable
private final class StubProvider: MuseScoreGeneralProvider {
    @ObservationIgnored nonisolated let downloadedURL: URL?
    @ObservationIgnored nonisolated let optedInSync: Bool
    var isOptedIn: Bool
    var downloadState: SoundfontDownloadState

    init(downloadedURL: URL?, optedIn: Bool = true) {
        self.downloadedURL = downloadedURL
        optedInSync = optedIn
        isOptedIn = optedIn
        downloadState = downloadedURL == nil ? .idle : .downloaded
    }

    var isDownloaded: Bool {
        downloadedURL != nil
    }

    var museScoreGeneralFileURL: URL? {
        downloadedURL
    }

    nonisolated var museScoreGeneralFileURLSync: URL? {
        // `downloadedURL` is set once during init and never mutated; safe to read without an actor hop.
        downloadedURL
    }

    nonisolated var isOptedInSync: Bool {
        // `optedInSync` is set once during init and never mutated; safe to read without an actor hop.
        optedInSync
    }

    nonisolated var isCurrentlyWiFi: Bool {
        true
    }

    var currentPreset: SoundfontPreset {
        isDownloaded ? .highQuality : .lightweight
    }

    func setOptedIn(_: Bool) {}
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
