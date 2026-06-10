import Domain
import Foundation

/// Pure, host-testable mutations over `ReaderPreferences`. Every function re-seats the value
/// through `ReaderPreferences.init` so the type's clamping always runs (mirrors iOS
/// `ReaderPreferencesStore.mutate`). Sentinels: `tempo`/`a4` of `0` mean "no override" → `nil`.
///
/// The wirelet bridge that wraps this is a separate layer — it converts `Int32`↔`Int` and projects
/// to/from wire structs. This reducer is Domain-native (`Int`, `Double`) and has no JNI dependency.
enum ReaderPreferencesReducer {
    /// Re-seats `p` through `ReaderPreferences.init` so every clamping/normalization rule re-runs after a mutation.
    private static func reseat(_ p: ReaderPreferences) -> ReaderPreferences {
        ReaderPreferences(
            id: p.id, scoreItemID: p.scoreItemID, staffSize: p.staffSize,
            hiddenStaves: p.hiddenStaves, staffProgramOverrides: p.staffProgramOverrides,
            staffVolumeOverrides: p.staffVolumeOverrides, staffClefOverrides: p.staffClefOverrides,
            tempoMultiplier: p.tempoMultiplier, honorLayoutBreaks: p.honorLayoutBreaks,
            repeatMode: p.repeatMode, abRepeat: p.abRepeat, masterVolume: p.masterVolume,
            transposeSemitones: p.transposeSemitones, a4ReferenceHz: p.a4ReferenceHz,
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
    static func decode(_ json: String) -> ReaderPreferences? {
        guard let data = json.data(using: .utf8), !data.isEmpty else { return nil }
        return try? JSONDecoder().decode(ReaderPreferences.self, from: data)
    }

    /// Encodes `p` to a JSON blob for opaque persistence. Returns `""` if encoding fails (never expected for this
    /// `Codable` value type).
    static func encode(_ p: ReaderPreferences) -> String {
        guard let data = try? JSONEncoder().encode(p) else { return "" }
        return String(bytes: data, encoding: .utf8) ?? ""
    }
}
