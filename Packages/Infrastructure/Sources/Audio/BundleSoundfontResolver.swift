import Foundation
import SheetMusicAudio

/// `SoundfontResolver` for `SheetMusicAudio.PlaybackEngine` that looks
/// `.sf2` files up inside the host app bundle, mirroring the convention
/// used by swift-sheet-music's example app:
///
///   * `Sounds/BBB_PPP.sf2` — per-(bank, program) files.
///   * `Sounds/MuseScore_General.sf2` — the full GM fallback.
///
/// Returning `nil` is allowed and just means the corresponding voice
/// stays silent — useful in dev / CI builds where the SF2 files aren't
/// shipped.
public struct BundleSoundfontResolver: SheetMusicAudio.SoundfontResolver {
    private let bundle: Bundle

    public init(bundle: Bundle = .main) {
        self.bundle = bundle
    }

    public func soundfontURL(forBank bank: UInt8, program: UInt8) -> URL? {
        let name = String(format: "%03d_%03d", bank, program)
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
