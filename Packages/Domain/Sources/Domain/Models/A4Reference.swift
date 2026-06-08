import Foundation

/// A4 reference-frequency (concert pitch) calibration for playback. Notation is
/// unaffected — this only shifts the audio. `cents` is the offset the audio engine
/// applies; `effectiveHz` resolves a per-score override against the global default.
public enum A4Reference {
    public static let minHz: Double = 415
    public static let maxHz: Double = 466
    public static let standardHz: Double = 440

    public static func clamp(_ hz: Double) -> Double {
        min(max(hz, minHz), maxHz)
    }

    /// Cents offset from A4=440 for a reference of `hz`. `1200·log2(hz/440)`.
    public static func cents(forHz hz: Double) -> Double {
        1200 * log2(hz / standardHz)
    }

    /// Per-score override wins; otherwise the global default.
    public static func effectiveHz(override: Double?, globalDefault: Double) -> Double {
        override ?? globalDefault
    }
}
