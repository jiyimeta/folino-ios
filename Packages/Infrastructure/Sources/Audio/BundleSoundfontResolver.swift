import Foundation
import SheetMusicAudio

/// Synchronous `SoundfontResolver` for `SheetMusicAudio.PlaybackEngine`.
/// `PlaybackEngine.prepare(score:)` calls this in-line, so it must
/// resolve from sources already on disk — anything that needs
/// downloading should be pre-fetched (see `MuseScoreSF2Resolver` and
/// `LivePlaybackController.load`).
///
/// Lookup order, first hit wins:
///
///   1. `cacheDirectory/BBB_PPP.sf2` — patches downloaded at runtime.
///   2. `bundle/Sounds/BBB_PPP.sf2` — patches shipped with the app.
///   3. `bundle/Sounds/MuseScore_General.sf2` — full GM fallback,
///      consulted by the engine via `defaultGMSoundfontURL` only when
///      the per-program lookup returns `nil`.
///
/// Returning `nil` is allowed; voices without a matched file stay
/// silent.
public struct BundleSoundfontResolver: SheetMusicAudio.SoundfontResolver {
    private let cacheDirectory: URL?
    private let bundle: Bundle

    public init(cacheDirectory: URL? = nil, bundle: Bundle = .main) {
        self.cacheDirectory = cacheDirectory
        self.bundle = bundle
    }

    public func soundfontURL(forBank bank: UInt8, program: UInt8) -> URL? {
        let name = String(format: "%03d_%03d", bank, program)
        if let cacheDirectory {
            let cached = cacheDirectory.appending(path: "\(name).sf2")
            if FileManager.default.fileExists(atPath: cached.path) {
                return cached
            }
        }
        return bundle.url(
            forResource: name, withExtension: "sf2", subdirectory: "Sounds"
        )
    }

    public var defaultGMSoundfontURL: URL? {
        bundle.url(
            forResource: "MuseScore_General",
            withExtension: "sf2",
            subdirectory: "Sounds"
        )
    }
}
