import Domain
import Foundation

/// Pure, host-testable mutations over `ReaderPreferences`. Every function re-seats the value
/// through `ReaderPreferences.init` so the type's clamping always runs (mirrors iOS
/// `ReaderPreferencesStore.mutate`). Sentinels: `tempo`/`a4` of `0` mean "no override" → `nil`.
///
/// The wirelet bridge that wraps this is a separate layer — it converts `Int32`↔`Int` and projects
/// to/from wire structs. This reducer is Domain-native (`Int`, `Double`) and has no JNI dependency.
///
/// The `set…` verbs always record an explicit choice, even when the value equals the current default: a Kotlin-side
/// set is a user action. Only the `clear…` verbs write "untouched" (`nil`), and they are what the UI's reset
/// affordances must call — matching iOS, where reset goes back to untouched.
enum ReaderPreferencesReducer {
    /// Re-seats `p` through `ReaderPreferences.init` so every clamping/normalization rule re-runs after a mutation.
    ///
    /// EVERY field must be listed here. A field left out is silently reset to the initializer's default on the next
    /// mutation — which is how `hasSeededAuthoredVisibility` used to be dropped, making the Reader re-hide staves the
    /// user had revealed. The clamping is `Optional.map`-based on the model side, so an untouched (`nil`) scalar
    /// stays `nil` through the round-trip.
    private static func reseat(_ p: ReaderPreferences) -> ReaderPreferences {
        ReaderPreferences(
            id: p.id, scoreItemID: p.scoreItemID, staffSize: p.staffSize,
            hiddenStaves: p.hiddenStaves, authoredHiddenStaves: p.authoredHiddenStaves,
            staffProgramOverrides: p.staffProgramOverrides,
            staffVolumeOverrides: p.staffVolumeOverrides, staffClefOverrides: p.staffClefOverrides,
            tempoMultiplier: p.tempoMultiplier, honorLayoutBreaks: p.honorLayoutBreaks,
            repeatMode: p.repeatMode, abRepeat: p.abRepeat, masterVolume: p.masterVolume,
            transposeSemitones: p.transposeSemitones, a4ReferenceHz: p.a4ReferenceHz,
            hasSeededAuthoredVisibility: p.hasSeededAuthoredVisibility,
        )
    }

    static func setStaffSize(_ p: ReaderPreferences, _ v: Double) -> ReaderPreferences {
        var c = p
        c.staffSize = v
        return reseat(c)
    }

    static func setHonorLayoutBreaks(_ p: ReaderPreferences, _ v: Bool) -> ReaderPreferences {
        var c = p
        c.honorLayoutBreaks = v
        return reseat(c)
    }

    static func setMasterVolume(_ p: ReaderPreferences, _ v: Double) -> ReaderPreferences {
        var c = p
        c.masterVolume = v
        return reseat(c)
    }

    static func setTempoMultiplier(_ p: ReaderPreferences, _ v: Double) -> ReaderPreferences {
        var c = p
        c.tempoMultiplier = (v == 0 ? nil : v)
        return reseat(c)
    }

    static func setA4ReferenceHz(_ p: ReaderPreferences, _ v: Double) -> ReaderPreferences {
        var c = p
        c.a4ReferenceHz = (v == 0 ? nil : v)
        return reseat(c)
    }

    static func setTranspose(_ p: ReaderPreferences, _ v: Int) -> ReaderPreferences {
        var c = p
        c.transposeSemitones = v
        return reseat(c)
    }

    /// Reset master volume to "the user never chose one" (`nil`), so it resolves to the current default. Distinct
    /// from `setMasterVolume(_, defaultMasterVolume)`, which records an explicit choice that happens to equal the
    /// default. Mirrors iOS `MasterVolumeModel.resetValue`.
    static func clearMasterVolume(_ p: ReaderPreferences) -> ReaderPreferences {
        var c = p
        c.masterVolume = nil
        return reseat(c)
    }

    /// Reset transposition to "untouched" (`nil`) rather than an explicit `0`, so the score stops counting as one the
    /// user transposed. Mirrors iOS `TransposeModel.reset`.
    static func clearTranspose(_ p: ReaderPreferences) -> ReaderPreferences {
        var c = p
        c.transposeSemitones = nil
        return reseat(c)
    }

    static func setStaffHidden(_ p: ReaderPreferences, part: Int, staff: Int, hidden: Bool) -> ReaderPreferences {
        var c = p
        let a = StaffAddress(partIndex: part, staffIndexInPart: staff)
        if hidden { c.hiddenStaves.insert(a) } else { c.hiddenStaves.remove(a) }
        return reseat(c)
    }

    static func setClef(_ p: ReaderPreferences, part: Int, staff: Int, rawType: String) -> ReaderPreferences {
        var c = p
        let a = StaffAddress(partIndex: part, staffIndexInPart: staff)
        if rawType.isEmpty { c.staffClefOverrides[a] = nil } else { c.staffClefOverrides[a] = rawType }
        return reseat(c)
    }

    static func setStaffProgram(_ p: ReaderPreferences, part: Int, staff: Int, program: Int) -> ReaderPreferences {
        var c = p
        c.staffProgramOverrides[StaffAddress(partIndex: part, staffIndexInPart: staff)] = program
        return reseat(c)
    }

    static func setStaffVolume(_ p: ReaderPreferences, part: Int, staff: Int, volume: Double) -> ReaderPreferences {
        var c = p
        c.staffVolumeOverrides[StaffAddress(partIndex: part, staffIndexInPart: staff)] = volume
        return reseat(c)
    }

    /// Decodes a stored JSON blob back into `ReaderPreferences`. Returns `nil` for empty / invalid input — the
    /// caller treats `nil` as "no saved preferences yet" and seeds defaults.
    ///
    /// This is the raw decode. Any caller that knows the Reader's current global default staff size should use
    /// `decode(_:defaultStaffSize:)` instead — see the note there on what Domain's legacy normalization cannot fix
    /// on its own.
    static func decode(_ json: String) -> ReaderPreferences? {
        guard let data = json.data(using: .utf8), !data.isEmpty else { return nil }
        return try? JSONDecoder().decode(ReaderPreferences.self, from: data)
    }

    /// Decodes a stored blob and applies the one legacy correction Domain cannot make on its own.
    ///
    /// `ReaderPreferences.init(from:)` demotes a legacy (pre-`schemaVersion`) `staffSize` to "untouched" only when it
    /// equals the frozen constant `14` — the value iOS seeded. Android's since-removed eager seed wrote the Reader's
    /// *global* default staff size instead (`MainActivity` passes `defaultStaffSize = prefs.staffSize`, a
    /// user-variable setting whose initial value is `28`), so a legacy Android blob carries whatever that global was
    /// when the score was first opened. Left alone it decodes as `.some`, permanently marking every score any Android
    /// user has ever opened as one with an explicitly configured staff size.
    ///
    /// The rule mirrors the iOS v16 migration exactly — "the stored value equals the default in effect, so treat it
    /// as untouched" — with the default supplied by the caller, because on Android it is user-variable and only this
    /// layer knows it. Same accepted trade-off as iOS: a user who deliberately chose a size that happens to equal the
    /// current global is reclassified as untouched. It is also approximate in the other direction — a user who has
    /// since moved the global keeps the stored value — which errs toward preserving data.
    ///
    /// There is no user-visible effect: a cleared `staffSize` resolves back through `effectiveStaffSize(default:)` to
    /// the very global it was compared against, so the score renders identically. If the user later moves the global,
    /// an untouched score follows it, which is the intent.
    ///
    /// A v2 blob is authoritative and is never touched.
    static func decode(_ json: String, defaultStaffSize: Double) -> ReaderPreferences? {
        guard var prefs = decode(json) else { return nil }
        guard isLegacyBlob(json) else { return prefs }
        // The legacy write path clamped as it stored, so compare against the clamped default.
        let seeded = min(max(defaultStaffSize, ReaderPreferences.minStaffSize), ReaderPreferences.maxStaffSize)
        guard prefs.staffSize == seeded else { return prefs }
        prefs.staffSize = nil
        return prefs
    }

    /// Whether `json` predates the `schemaVersion` marker, i.e. was written before "untouched is `nil`" existed. Only
    /// such a blob is subject to a legacy correction; see `ReaderPreferences.init(from:)`.
    static func isLegacyBlob(_ json: String) -> Bool {
        guard let data = json.data(using: .utf8), !data.isEmpty,
              let probe = try? JSONDecoder().decode(SchemaVersionProbe.self, from: data)
        else { return false }
        return probe.schemaVersion == nil
    }

    /// Reads just the schema marker out of a stored blob, ignoring every other key.
    private struct SchemaVersionProbe: Decodable {
        let schemaVersion: Int?
    }

    /// Encodes `p` to a JSON blob for opaque persistence. Returns `""` if encoding fails (never expected for this
    /// `Codable` value type).
    static func encode(_ p: ReaderPreferences) -> String {
        guard let data = try? JSONEncoder().encode(p) else { return "" }
        return String(bytes: data, encoding: .utf8) ?? ""
    }
}
