/// Output calibration for the SwiftySynth backend, applied on top of the user's master volume.
///
/// SwiftySynth measures ~14 dB below the AUMIDISynth path folino shipped through 1.7.x, which users hear as playback
/// being far too quiet. The gap is not a defect in either synth: the old path peaked *above* full scale on a single
/// note and leaned on the master limiter, so matching it exactly would mean reproducing distortion, and avoiding those
/// artifacts is why we moved backends. What the right playback level is, though, is a product question about how
/// folino should sound — not something the engine can decide — so the calibration lives here rather than in
/// `swift-sheet-music`.
///
/// 5× (+14 dB) restores parity with what users are used to. This deliberately does NOT touch
/// `ReaderPreferences.masterVolume`, whose contract stays "1.0 = the score's authored level, boostable to 300%" — that
/// value is persisted per score, so folding calibration into it would both corrupt saved preferences and leave
/// already-opened scores behind.
///
/// Shared by live playback (`LivePlaybackController.applyMasterVolume`) and the offline export
/// (`LiveScoreAudioExporter`): both render through `SwiftySynthBackend`, so both need the same calibration or the two
/// sit ~14 dB apart.
enum BackendOutputCalibration {
    static let gain: Double = 5
}
