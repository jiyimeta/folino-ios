import WireletProvided

/// Per-score Reader-preferences persistence, *implemented in Kotlin* (Room
/// `reader_preferences` table) and injected into `ReaderPreferencesBridge` over JNI.
///
/// Rule-free: it stores/returns the opaque JSON blob the Swift bridge hands it.
/// All shape + clamping lives in the shared Domain `ReaderPreferences`, in
/// lockstep with iOS.
@WireletProvided
public protocol ReaderPreferencesStore {
    /// The stored JSON for `scoreId`, or `nil` if none has been saved yet.
    func loadJSON(scoreId: String) -> String?
    /// Insert or replace the stored JSON for `scoreId`.
    func saveJSON(scoreId: String, json: String)
}
