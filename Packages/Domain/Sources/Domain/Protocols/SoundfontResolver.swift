import Foundation

/// Provides URLs for SoundFont 2 (`.sf2`) files keyed by (bank, program). Bundled patches resolve to URLs inside the
/// app bundle; downloaded patches resolve to `Caches/Soundfonts/`. The Settings UI uses this protocol's cache
/// management methods to display sizes and delete entries.
public protocol SoundfontResolver: Sendable {
    /// Resolve a `(bank, program, isDrums)` to a local `.sf2` file URL, downloading and caching if necessary. `isDrums:
    /// true` requests the percussion file (e.g. `128_000.sf2`); `false` requests the melodic file (e.g. `000_073.sf2`).
    func resolveSoundfont(bank: Int, program: Int, isDrums: Bool) async throws -> URL

    /// All patches currently cached on disk. Includes bundled patches with `isBundled = true`.
    func cachedPatches() async throws -> [SoundfontPatch]

    /// Total disk usage of cached patches that are not bundled.
    func totalCacheSizeBytes() async throws -> Int64

    /// Remove a single cached (non-bundled) patch. No-op if the patch was bundled or missing.
    func deletePatch(bank: Int, program: Int, isDrums: Bool) async throws

    /// Remove every non-bundled cached patch.
    func clearCache() async throws
}
