/// Identifies which GM SoundFont tier is currently serving the playback engine. The mapping from these abstract tiers
/// to concrete `.sf2` files is the resolver's responsibility — callers should not assume a particular SF2 vendor or
/// format. Two tiers: a small bundled default that is always available, and an optional higher-quality download.
public enum SoundfontPreset: String, Sendable, Hashable, CaseIterable {
    /// Small SF2 shipped inside the app bundle. Always available — the audio engine falls back here when no upgrade is
    /// downloaded.
    case lightweight
    /// Larger SF2 fetched on demand (Wi-Fi by default) when the user opts in. Higher fidelity than `.lightweight`.
    case highQuality

    /// On-disk file name the resolver looks up under `Bundle.main/Soundfonts/` (for `.lightweight`) or
    /// `Application Support/Soundfonts/` (for `.highQuality`). Layers other than the resolver should not introspect
    /// this — the case itself is the contract.
    public var fileName: String {
        switch self {
        case .lightweight: "GeneralUser-GS.sf2"
        case .highQuality: "MuseScore_General.sf2"
        }
    }

    /// Approximate uncompressed size used by Settings to label the toggle. Real file size on disk is read by the
    /// provider when available.
    public var sizeBytes: Int64 {
        switch self {
        case .lightweight: 31 * 1024 * 1024
        case .highQuality: 206 * 1024 * 1024
        }
    }

    /// `true` for the bundled lightweight preset, which ships inside the app bundle and is available without a
    /// network download.
    public var isBundled: Bool {
        self == .lightweight
    }
}
