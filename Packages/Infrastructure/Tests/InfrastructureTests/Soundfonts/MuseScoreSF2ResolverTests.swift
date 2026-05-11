import Domain
import Foundation
@testable import Soundfonts
import Testing

/// `.serialized` because the async download tests share `StubURLProtocol.next`
/// global state — running them in parallel would let one suite's stubbed
/// response leak into another.
@Suite(.serialized) struct MuseScoreSF2ResolverTests {
    // MARK: - File naming

    @Test func `melodic file name uses bank and program`() {
        #expect(MuseScoreSF2Resolver.fileName(bank: 0, program: 73, isDrums: false) == "000_073.sf2")
        #expect(MuseScoreSF2Resolver.fileName(bank: 8, program: 0, isDrums: false) == "008_000.sf2")
    }

    @Test func `drum file name always uses bank 128`() {
        #expect(MuseScoreSF2Resolver.fileName(bank: 0, program: 0, isDrums: true) == "128_000.sf2")
        // Bank arg is ignored for drums — both produce 128_PPP.
        #expect(MuseScoreSF2Resolver.fileName(bank: 7, program: 25, isDrums: true) == "128_025.sf2")
    }

    // MARK: - Sync lookup chain

    @Test func `cache hit wins over bundle and fallback`() throws {
        let tmp = try TempDirectory()
        let cache = tmp.url
        // Pretend (0, 73, false) is in the cache.
        let cachedFile = cache.appending(path: "000_073.sf2")
        try Data([0xAA]).write(to: cachedFile)

        let bundle = try makeFakeBundle(
            tmp: tmp,
            files: ["Soundfonts/000_073.sf2": Data([0xBB])],
        )
        let resolver = MuseScoreSF2Resolver(cacheDirectory: cache, bundle: bundle)

        let url = resolver.soundfontURL(forBank: 0, program: 73, isDrums: false)
        #expect(url == cachedFile)
    }

    @Test func `bundle hit wins over fallback when cache empty`() throws {
        let tmp = try TempDirectory()
        let bundleFile = "Soundfonts/008_000.sf2"
        let bundle = try makeFakeBundle(
            tmp: tmp,
            files: [bundleFile: Data([0xBB])],
        )
        let resolver = MuseScoreSF2Resolver(cacheDirectory: tmp.url, bundle: bundle)

        let url = resolver.soundfontURL(forBank: 8, program: 0, isDrums: false)
        #expect(url?.lastPathComponent == "008_000.sf2")
        #expect(url?.path.contains(tmp.url.path) == true)
    }

    @Test func `pitched miss falls back to flute`() throws {
        let tmp = try TempDirectory()
        let bundle = try makeFakeBundle(
            tmp: tmp,
            files: ["Soundfonts/000_073.sf2": Data([0xFF])],
        )
        let resolver = MuseScoreSF2Resolver(cacheDirectory: tmp.url, bundle: bundle)

        let url = resolver.soundfontURL(forBank: 5, program: 42, isDrums: false)
        #expect(url?.lastPathComponent == "000_073.sf2")
    }

    @Test func `drum miss falls back to standard kit`() throws {
        let tmp = try TempDirectory()
        let bundle = try makeFakeBundle(
            tmp: tmp,
            files: ["Soundfonts/128_000.sf2": Data([0xCC])],
        )
        let resolver = MuseScoreSF2Resolver(cacheDirectory: tmp.url, bundle: bundle)

        let url = resolver.soundfontURL(forBank: 0, program: 25, isDrums: true)
        #expect(url?.lastPathComponent == "128_000.sf2")
    }

    @Test func `default GM soundfont URL is nil`() throws {
        let tmp = try TempDirectory()
        let resolver = MuseScoreSF2Resolver(cacheDirectory: tmp.url)
        #expect(resolver.defaultGMSoundfontURL == nil)
    }

    @Test func `precise path returns nil when no cache or bundle hit`() throws {
        let tmp = try TempDirectory()
        let bundle = try makeFakeBundle(
            tmp: tmp,
            files: ["Soundfonts/128_000.sf2": Data([0xCC])],
        )
        let resolver = MuseScoreSF2Resolver(cacheDirectory: tmp.url, bundle: bundle)

        // Pitched lookup that has no precise file — even though the
        // drum fallback bundle is present, precisePath must return nil.
        #expect(resolver.precisePath(forBank: 5, program: 42, isDrums: false) == nil)
        // Drum lookup whose precise file IS the same as the fallback name —
        // must return the bundle URL (it's a precise hit, not a fallthrough).
        #expect(resolver.precisePath(forBank: 0, program: 0, isDrums: true) != nil)
    }

    // MARK: - Async download path

    @Test func `resolve soundfont returns cache hit`() async throws {
        let tmp = try TempDirectory()
        let cached = tmp.url.appending(path: "000_073.sf2")
        try Data([0xAA]).write(to: cached)
        let resolver = MuseScoreSF2Resolver(cacheDirectory: tmp.url, session: stubSession())

        let url = try await resolver.resolveSoundfont(bank: 0, program: 73, isDrums: false)
        #expect(url == cached)
    }

    @Test func `resolve soundfont returns bundle hit without download`() async throws {
        let tmp = try TempDirectory()
        let bundle = try makeFakeBundle(
            tmp: tmp,
            files: ["Soundfonts/000_073.sf2": Data([0xBB])],
        )
        // Stub session would 500 if hit — assert it isn't.
        let resolver = MuseScoreSF2Resolver(
            cacheDirectory: tmp.url.appending(path: "cache"),
            session: stubSession(failing: true),
            bundle: bundle,
        )

        let url = try await resolver.resolveSoundfont(bank: 0, program: 73, isDrums: false)
        #expect(url.lastPathComponent == "000_073.sf2")
    }

    @Test func `resolve soundfont downloads to cache on miss`() async throws {
        let tmp = try TempDirectory()
        let payload = Data([0xDE, 0xAD, 0xBE, 0xEF])
        let resolver = MuseScoreSF2Resolver(
            cacheDirectory: tmp.url,
            session: stubSession(payload: payload, status: 200),
        )

        let url = try await resolver.resolveSoundfont(bank: 8, program: 0, isDrums: false)
        #expect(url == tmp.url.appending(path: "008_000.sf2"))
        let written = try Data(contentsOf: url)
        #expect(written == payload)
    }

    @Test func `resolve soundfont throws on non 200`() async throws {
        let tmp = try TempDirectory()
        let resolver = MuseScoreSF2Resolver(
            cacheDirectory: tmp.url,
            session: stubSession(payload: Data(), status: 404),
        )
        await #expect(throws: DomainError.self) {
            _ = try await resolver.resolveSoundfont(bank: 8, program: 0, isDrums: false)
        }
    }
}

// MARK: - Test helpers

/// Builds a real on-disk `Bundle` so `Bundle.url(forResource:...)` works.
/// Files are written under `tmp.url/FakeBundle.bundle/<relative path>`.
private func makeFakeBundle(tmp: TempDirectory, files: [String: Data]) throws -> Bundle {
    let bundleURL = tmp.url.appending(path: "FakeBundle.bundle", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
    for (relative, data) in files {
        let target = bundleURL.appending(path: relative)
        try FileManager.default.createDirectory(
            at: target.deletingLastPathComponent(), withIntermediateDirectories: true,
        )
        try data.write(to: target)
    }
    guard let bundle = Bundle(url: bundleURL) else {
        throw NSError(domain: "TestBundle", code: 1)
    }
    return bundle
}

/// Returns a `URLSession` whose `URLProtocol` either serves a fixed payload
/// or throws — chosen at construction so a single test stays declarative.
private func stubSession(
    payload: Data = Data(),
    status: Int = 200,
    failing: Bool = false,
) -> URLSession {
    StubURLProtocol.next = StubURLProtocol.Response(
        payload: payload, status: status, failing: failing,
    )
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [StubURLProtocol.self]
    return URLSession(configuration: config)
}

private final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    struct Response { let payload: Data; let status: Int; let failing: Bool }
    nonisolated(unsafe) static var next: Response?

    // swiftlint:disable:next static_over_final_class
    override class func canInit(with _: URLRequest) -> Bool {
        true
    }

    // swiftlint:disable:next static_over_final_class
    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let response = StubURLProtocol.next else {
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        if response.failing {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        // swiftlint:disable force_unwrapping
        let httpResponse = HTTPURLResponse(
            url: request.url!, statusCode: response.status,
            httpVersion: "HTTP/1.1", headerFields: nil,
        )!
        // swiftlint:enable force_unwrapping
        client?.urlProtocol(self, didReceive: httpResponse, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: response.payload)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
