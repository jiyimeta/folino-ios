import Domain
import Foundation
import SheetMusicAudio

/// Adapter from `SheetMusicAudio.SoundfontResolver` to Folino's GM-only sound model. The audio engine asks this
/// resolver for `defaultGMSoundfontURL` every time it loads a score; we hand back either the downloaded high-quality
/// URL (preferred when present + opted in) or the bundled lightweight URL.
public struct GMSoundfontResolver: SheetMusicAudio.SoundfontResolver {
    private let provider: any MuseScoreGeneralProvider
    private let bundle: Bundle

    public init(provider: any MuseScoreGeneralProvider, bundle: Bundle = .main) {
        self.provider = provider
        self.bundle = bundle
    }

    /// Always `nil` — the engine falls through to `defaultGMSoundfontURL`, which carries the full GM bank (including
    /// drum bank 128 used by the metronome on MIDI channel 9). Returning nil here keeps the engine code path identical
    /// for every voice in every score.
    public func soundfontURL(forBank _: UInt8, program _: UInt8, isDrums _: Bool) -> URL? {
        nil
    }

    public var defaultGMSoundfontURL: URL? {
        // `museScoreGeneralFileURLSync` is `nonisolated` on the provider and reads only the immutable
        // `targetDirectory` constant plus `FileManager.fileExists`, so this is safe to call from the
        // audio thread without an actor hop.
        if let downloaded = provider.museScoreGeneralFileURLSync {
            return downloaded
        }
        return bundle.url(
            forResource: "GeneralUser-GS",
            withExtension: "sf2",
            subdirectory: "Soundfonts",
        )
    }
}
