/// The GM SoundFont actively serving the playback engine. Folino ships GeneralUser GS bundled (always available); the
/// MuseScore_General upgrade is opted into via Settings and downloaded over the network the first time the toggle is on
/// and Wi-Fi is reachable.
public enum SoundfontPreset: String, Sendable, Hashable, CaseIterable {
    case generalUserGS
    case museScoreGeneral

    /// SF2 file name expected under `Bundle.main/Soundfonts/` (bundled) or `Application Support/Soundfonts/`
    /// (downloaded).
    public var fileName: String {
        switch self {
        case .generalUserGS: "GeneralUser-GS.sf2"
        case .museScoreGeneral: "MuseScore_General.sf2"
        }
    }

    /// Approximate uncompressed size used by Settings to label the toggle. Real file size on disk is read by the
    /// provider when available.
    public var sizeBytes: Int64 {
        switch self {
        case .generalUserGS: 31 * 1024 * 1024
        case .museScoreGeneral: 206 * 1024 * 1024
        }
    }

    /// `true` for `generalUserGS`, which ships inside the app bundle and is always available
    /// without a network download.
    public var isBundled: Bool {
        self == .generalUserGS
    }
}
