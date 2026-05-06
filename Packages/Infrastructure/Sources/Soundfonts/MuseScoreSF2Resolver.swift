import Domain
import Foundation

/// Downloads per-(bank, program) `.sf2` files from
/// `jiyimeta/musescore-general-sf2-split` GitHub releases the first
/// time they're needed, then serves them out of `cacheDirectory` on
/// subsequent calls. Files use the release naming `BBB_PPP.sf2`
/// (zero-padded decimal bank / program).
///
/// Patterned after the reference `SoundFontFileManager` in the
/// MIDIPlayer companion app — same release URL, same naming, but
/// adapted to Folino's `Domain.SoundfontResolver` protocol.
public struct MuseScoreSF2Resolver: SoundfontResolver {
    /// Default base URL for the SF2 split release. Files live at
    /// `<baseURL>/BBB_PPP.sf2`.
    public static let defaultBaseURL = URL(
        string: "https://github.com/jiyimeta/musescore-general-sf2-split/releases/download/1.0.0"
    )! // swiftlint:disable:this force_unwrapping

    private let cacheDirectory: URL
    private let baseURL: URL
    private let session: URLSession

    public init(
        cacheDirectory: URL,
        baseURL: URL = MuseScoreSF2Resolver.defaultBaseURL,
        session: URLSession = .shared
    ) {
        self.cacheDirectory = cacheDirectory
        self.baseURL = baseURL
        self.session = session
    }

    public func resolveSoundfont(bank: Int, program: Int) async throws -> URL {
        let fileName = Self.fileName(bank: bank, program: program)
        let local = cacheDirectory.appending(path: fileName)
        if FileManager.default.fileExists(atPath: local.path) {
            return local
        }
        try createCacheDirectoryIfNeeded()
        let remote = baseURL.appending(path: fileName)
        let (data, response) = try await session.data(from: remote)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw DomainError.soundfontDownloadFailed(
                SoundfontPatchKey(bank: bank, program: program)
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
            return SoundfontPatch(
                bank: parsed.bank, program: parsed.program,
                localFileName: url.lastPathComponent,
                sizeBytes: size,
                downloadedAt: modified,
                lastUsedAt: modified,
                isBundled: false
            )
        }
    }

    public func totalCacheSizeBytes() throws -> Int64 {
        try cachedPatches().reduce(0) { $0 + $1.sizeBytes }
    }

    public func deletePatch(bank: Int, program: Int) throws {
        let url = cacheDirectory.appending(path: Self.fileName(bank: bank, program: program))
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

    static func fileName(bank: Int, program: Int) -> String {
        String(format: "%03d_%03d.sf2", bank, program)
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
