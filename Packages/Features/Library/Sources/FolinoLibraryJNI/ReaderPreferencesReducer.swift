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

    /// `0` is the wire's "no override" sentinel. The unity window is the deliberate exception to this type's rule
    /// that a `set…` always records an explicit choice: it mirrors iOS `TempoModel.commitMultiplier`, where a
    /// slider that stops visually at 100% clears the override rather than pinning one the user thought they had
    /// released. It is also what makes Android's two reset affordances clear — both route through `onRate(1.0f)`,
    /// not a `clear…` verb. An explicit `1.0` is therefore unrepresentable here, exactly as on iOS.
    static func setTempoMultiplier(_ p: ReaderPreferences, _ v: Double) -> ReaderPreferences {
        var c = p
        c.tempoMultiplier = (v == 0 || abs(v - 1.0) < 0.005) ? nil : v
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

    /// Reset staff size to "the user never chose one" (`nil`), so it resolves to the current device-class default.
    /// The Compose affordance is the slider's double-tap; it used to write a hardcoded `28.0`, which both marked the
    /// score as configured and ignored the device default it was supposed to return to.
    static func clearStaffSize(_ p: ReaderPreferences) -> ReaderPreferences {
        var c = p
        c.staffSize = nil
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

    /// What Android's since-removed eager seed wrote for a staff size the user never chose. `SettingsPrefs`' global
    /// `staffSize` key has existed since `db9ca50e` and was `28.0` in every build that **shipped**. There is one
    /// known exception: from `33dff903` (2026-06-05) to `9f9c10a4` (2026-06-10) the Display inspector's slider
    /// wrote through `SettingsPrefs.setStaffSize` to this global key, before that commit moved it to the per-score
    /// bridge — five days of dev-only history, not a released build; Android has not shipped to the Play Store, so
    /// the affected population is dev/test devices only. A blob seeded from the global during that window decodes
    /// as an explicit staff size and stays pinned. Frozen for the same reason `ReaderPreferences.LegacyStoredDefaults`
    /// is: a migration has to keep describing the data as it was written, even after the live defaults move (which
    /// they now have, to 21 on a phone and 24 on a tablet).
    private enum LegacyAndroidSeed {
        static let staffSize: Double = 28
    }

    /// Decodes a stored JSON blob back into `ReaderPreferences`, applying the one legacy correction Domain cannot
    /// make on its own. Returns `nil` for empty / invalid input — the caller treats `nil` as "no saved preferences
    /// yet" and seeds defaults.
    ///
    /// `ReaderPreferences.init(from:)` demotes a legacy (pre-`schemaVersion`) `staffSize` only when it equals the
    /// frozen constant `14`, the value iOS seeded. Android's eager seed wrote its own global instead. Left alone
    /// such a blob decodes as `.some`, permanently marking every score any Android user has ever opened as one with
    /// an explicitly configured staff size.
    ///
    /// The rule mirrors the iOS v16 migration — "the stored value equals the seed that was in effect, so treat it as
    /// untouched" — and carries the same accepted trade-off: a user who deliberately chose 28 (the slider maximum) is
    /// reclassified as untouched. That was already true when 28 was also the live default, so this is not a
    /// regression.
    ///
    /// There is no user-visible effect on a phone or tablet whose default is now 21 / 24: the score re-engraves at the
    /// current default, which is the intent of the defaults change. A v2 blob is authoritative and is never touched.
    static func decode(_ json: String) -> ReaderPreferences? {
        guard let data = json.data(using: .utf8), !data.isEmpty,
              var prefs = try? JSONDecoder().decode(ReaderPreferences.self, from: data)
        else { return nil }
        guard isLegacyBlob(json), prefs.staffSize == LegacyAndroidSeed.staffSize else { return prefs }
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
