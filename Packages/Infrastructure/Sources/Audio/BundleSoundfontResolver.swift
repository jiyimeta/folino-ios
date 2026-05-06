import Foundation
import SheetMusicAudio

/// Synchronous `SoundfontResolver` for `SheetMusicAudio.PlaybackEngine`.
///
/// Mirrors `swift-sheet-music`'s example resolver: every staff load —
/// pitched, drumset, and the metronome — falls through to the bundled
/// full GM SoundFont (`Sounds/MuseScore_General.sf2`). The engine then
/// picks the melodic vs percussion bank via `bankMSB`, which the GM
/// SoundFont supplies in a single file.
///
/// We deliberately do NOT serve per-`(bank, program)` split files here.
/// `PlaybackEngine.prepare(score:)` calls
/// `soundfontURL(forBank: channel.bank, program: channel.program)` for
/// drumset staves with `bank == 0` (MSCX stores the SF2 bank in the
/// LSB; the MSB is inferred from `useDrumset`). A piano-only split
/// file at `000_000.sf2` would then be loaded with
/// `bankMSB == kAUSampler_DefaultPercussionBankMSB`, which fails
/// silently and leaves the sampler playing AVAudioUnitSampler's
/// default melodic patch. Forcing the GM fallback for every lookup
/// avoids that mismatch.
public struct BundleSoundfontResolver: SheetMusicAudio.SoundfontResolver {
    private let bundle: Bundle

    public init(bundle: Bundle = .main) {
        self.bundle = bundle
    }

    public func soundfontURL(forBank _: UInt8, program _: UInt8, isDrums _: Bool) -> URL? {
        nil
    }

    public var defaultGMSoundfontURL: URL? {
        bundle.url(
            forResource: "MuseScore_General",
            withExtension: "sf2",
            subdirectory: "Sounds"
        )
    }
}
