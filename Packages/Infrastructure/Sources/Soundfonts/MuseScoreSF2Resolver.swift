import Domain
import Foundation
import SheetMusicAudio

/// Single resolver that covers both Folino's async download path
/// (`Domain.SoundfontResolver`) and `swift-sheet-music`'s synchronous
/// per-(bank, program, isDrums) lookup (`SheetMusicAudio.SoundfontResolver`).
///
/// Lookup order, sync path:
///   1. Cache hit at `cacheDirectory/<name>` — return.
///   2. Bundle hit at `Bundle.main/Soundfonts/<name>` — return.
///   3. Drum lookup with no precise hit — return bundled
///      `Soundfonts/128_000.sf2` (Standard Drum Kit fallback).
///   4. Pitched lookup with no precise hit — return bundled
///      `Soundfonts/000_073.sf2` (Flute fallback).
///   5. Even the fallback bundle is missing (only happens in
///      misbuilt apps) — return `nil`.
///
/// Async path (`resolveSoundfont`):
///   1. Cache hit — return.
///   2. Bundle hit — return (no copy; bundle URL is fine).
///   3. Download `<baseURL>/<name>` to cache atomically — return.
///   4. Download fails — throw `DomainError.soundfontDownloadFailed`.
///
/// File naming follows `jiyimeta/musescore-general-sf2-split`:
///   - melodic: `BBB_PPP.sf2` (zero-padded decimal `bank`, `program`)
///   - drums:   `128_PPP.sf2` (drum bank prefix is `128`, ignoring `bank`)
public struct MuseScoreSF2Resolver: Domain.SoundfontResolver, SheetMusicAudio.SoundfontResolver {
    public static let defaultBaseURL = URL(
        string: "https://github.com/jiyimeta/musescore-general-sf2-split/releases/download/1.0.0"
    )! // swiftlint:disable:this force_unwrapping

    /// Subdirectory inside `Bundle.main` that hosts committed
    /// fallback SF2 files. Matches the folder reference set up in
    /// `project.yml`.
    static let bundleSubdirectory = "Soundfonts"
    /// Pitched fallback (GM Flute, ~624 KB).
    static let pitchedFallbackName = "000_073.sf2"
    /// Drum fallback (Standard Drum Kit, ~6.15 MB).
    static let drumFallbackName = "128_000.sf2"

    private let cacheDirectory: URL
    private let baseURL: URL
    private let session: URLSession
    private let bundle: Bundle

    public init(
        cacheDirectory: URL,
        baseURL: URL = MuseScoreSF2Resolver.defaultBaseURL,
        session: URLSession = .shared,
        bundle: Bundle = .main
    ) {
        self.cacheDirectory = cacheDirectory
        self.baseURL = baseURL
        self.session = session
        self.bundle = bundle
    }

    // MARK: - SheetMusicAudio.SoundfontResolver (sync)

    public func soundfontURL(forBank bank: UInt8, program: UInt8, isDrums: Bool) -> URL? {
        let name = Self.fileName(bank: Int(bank), program: Int(program), isDrums: isDrums)
        if let precise = precisePath(name: name) {
            return precise
        }
        let fallbackName = isDrums ? Self.drumFallbackName : Self.pitchedFallbackName
        return bundleURL(name: fallbackName)
    }

    public var defaultGMSoundfontURL: URL? { nil }

    /// Sync resolver path that returns `nil` if neither cache nor
    /// bundle has a precise file — used by `LivePlaybackController`
    /// to decide whether a staff needs a fallback channel rewrite.
    public func precisePath(forBank bank: Int, program: Int, isDrums: Bool) -> URL? {
        precisePath(name: Self.fileName(bank: bank, program: program, isDrums: isDrums))
    }

    private func precisePath(name: String) -> URL? {
        let cached = cacheDirectory.appending(path: name)
        if FileManager.default.fileExists(atPath: cached.path) {
            return cached
        }
        return bundleURL(name: name)
    }

    private func bundleURL(name: String) -> URL? {
        // `Bundle.url(forResource:withExtension:subdirectory:)`
        // wants the components split. Strip the `.sf2` suffix.
        guard name.hasSuffix(".sf2") else { return nil }
        let stem = String(name.dropLast(".sf2".count))
        return bundle.url(
            forResource: stem,
            withExtension: "sf2",
            subdirectory: Self.bundleSubdirectory
        )
    }

    // MARK: - Domain.SoundfontResolver (async)

    public func resolveSoundfont(bank: Int, program: Int, isDrums: Bool) async throws -> URL {
        let name = Self.fileName(bank: bank, program: program, isDrums: isDrums)
        if let precise = precisePath(name: name) {
            return precise
        }
        try createCacheDirectoryIfNeeded()
        let local = cacheDirectory.appending(path: name)
        let remote = baseURL.appending(path: name)
        let (data, response) = try await session.data(from: remote)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw DomainError.soundfontDownloadFailed(
                SoundfontPatchKey(bank: bank, program: program, isDrums: isDrums)
            )
        }
        try data.write(to: local, options: .atomic)
        return local
    }

    public func cachedPatches() throws -> [SoundfontPatch] {
        try createCacheDirectoryIfNeeded()
        let urls = try FileManager.default.contentsOfDirectory(
            at: cacheDirectory,
            includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )
        return urls.compactMap { url -> SoundfontPatch? in
            guard url.pathExtension.lowercased() == "sf2",
                  let parsed = Self.parseFileName(url.lastPathComponent)
            else { return nil }
            let attrs = (try? FileManager.default.attributesOfItem(atPath: url.path)) ?? [:]
            let size = (attrs[.size] as? NSNumber)?.int64Value ?? 0
            let modified = (attrs[.modificationDate] as? Date) ?? .distantPast
            // The file naming convention encodes drum banks as `128_PPP`.
            // Surface that into the cache record so `id` and the Settings
            // UI can disambiguate `(0, 0)` Acoustic Grand from `(0, 0)` Std Kit.
            let isDrums = parsed.bank == 128
            let recordedBank = isDrums ? 0 : parsed.bank
            return SoundfontPatch(
                bank: recordedBank, program: parsed.program,
                localFileName: url.lastPathComponent,
                sizeBytes: size,
                downloadedAt: modified,
                lastUsedAt: modified,
                isBundled: false,
                isDrums: isDrums
            )
        }
    }

    public func totalCacheSizeBytes() throws -> Int64 {
        try cachedPatches().reduce(0) { $0 + $1.sizeBytes }
    }

    public func deletePatch(bank: Int, program: Int, isDrums: Bool) throws {
        let name = Self.fileName(bank: bank, program: program, isDrums: isDrums)
        let url = cacheDirectory.appending(path: name)
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    public func clearCache() throws {
        guard FileManager.default.fileExists(atPath: cacheDirectory.path) else { return }
        let urls = try FileManager.default.contentsOfDirectory(
            at: cacheDirectory, includingPropertiesForKeys: nil
        )
        for url in urls where url.pathExtension.lowercased() == "sf2" {
            try? FileManager.default.removeItem(at: url)
        }
    }

    // MARK: - Helpers

    static func fileName(bank: Int, program: Int, isDrums: Bool) -> String {
        let prefix = isDrums ? 128 : bank
        return String(format: "%03d_%03d.sf2", prefix, program)
    }

    static func parseFileName(_ name: String) -> (bank: Int, program: Int)? {
        // Expected shape: "BBB_PPP.sf2" with three-digit decimals.
        let stem = name.split(separator: ".").first.map(String.init) ?? name
        let parts = stem.split(separator: "_")
        guard parts.count == 2,
              let bank = Int(parts[0]),
              let program = Int(parts[1])
        else { return nil }
        return (bank, program)
    }

    private func createCacheDirectoryIfNeeded() throws {
        if !FileManager.default.fileExists(atPath: cacheDirectory.path) {
            try FileManager.default.createDirectory(
                at: cacheDirectory, withIntermediateDirectories: true
            )
        }
    }
}
