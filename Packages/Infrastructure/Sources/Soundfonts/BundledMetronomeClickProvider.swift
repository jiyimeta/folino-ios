import Foundation
import SheetMusicAudio

/// Tells `SheetMusicAudio.PlaybackEngine` to drive the metronome from folino's bundled click samples
/// (`Clicks/click_strong.wav` + `Clicks/click_weak.wav`) instead of the GM wood-block drum kit. The engine
/// converts the WAV pair to an SF2 once via `ClickSoundFontBuilder` and caches the result.
///
/// Falls back to `.defaultGM` when either sample is missing from the bundle, so a stripped resource set degrades
/// to the legacy click rather than silencing the metronome.
public struct BundledMetronomeClickProvider: MetronomeClickProvider {
    private let bundle: Bundle

    public init(bundle: Bundle = .main) {
        self.bundle = bundle
    }

    public func metronomeClickSource() -> MetronomeClickSource {
        guard
            let strong = bundle.url(forResource: "click_strong", withExtension: "wav", subdirectory: "Clicks"),
            let weak = bundle.url(forResource: "click_weak", withExtension: "wav", subdirectory: "Clicks")
        else {
            return .defaultGM
        }
        return .clickSamples(strong: strong, weak: weak)
    }
}
