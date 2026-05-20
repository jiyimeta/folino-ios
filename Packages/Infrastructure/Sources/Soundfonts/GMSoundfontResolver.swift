import Domain
import Foundation
import SheetMusicAudio

/// Adapter from `SheetMusicAudio.SoundfontResolver` to Folino's GM-only sound model. The audio engine asks this
/// resolver for `defaultGMSoundfontURL` every time it loads a score; we hand back either the downloaded
/// MuseScore_General URL (preferred when present + opted in) or the bundled GeneralUser GS URL.
public struct GMSoundfontResolver: SheetMusicAudio.SoundfontResolver {
    private let provider: any MuseScoreGeneralProvider
    private let bundle: Bundle

    public init(provider: any MuseScoreGeneralProvider, bundle: Bundle = .main) {
        self.provider = provider
        self.bundle = bundle
    }

    /// Always `nil` — the engine falls through to `defaultGMSoundfontURL`, which carries the full GM bank. Returning
    /// nil here keeps the engine code path identical for every voice in every score.
    public func soundfontURL(forBank _: UInt8, program _: UInt8, isDrums _: Bool) -> URL? {
        nil
    }

    public var defaultGMSoundfontURL: URL? {
        // Synchronous read of the provider's snapshot is fine because the file URL only changes on download completion
        // / deletion, both of which are user-initiated rare events. Audio thread tolerates an occasional cross-actor
        // hop via `unsafeWait` (see provider implementation).
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

extension MuseScoreGeneralProvider {
    /// Synchronous accessor used by the audio thread. Concrete providers override; default is `nil` to keep stub
    /// providers in tests trivially compliant.
    public var museScoreGeneralFileURLSync: URL? {
        nil
    }
}
