import Domain
import Observation
import WireletObservable

/// Android-side per-score Reader-preferences bridge, mirroring iOS's `ReaderPreferencesStore` but with the
/// JSON-blob persistence injected from Kotlin (`ReaderPreferencesStore` over `@WireletProvided`). All shape +
/// clamping lives in the shared Domain `ReaderPreferences`; the pure mutations run through
/// `ReaderPreferencesReducer`, so behavior matches iOS exactly.
///
/// The observable `state` projects the scalar fields to Compose as one `@WireFormat` struct (`honorLayoutBreaks`
/// is folded in because the observable emitter does not project a bare `Bool` stored property). The per-staff
/// collections (hidden / clef / program / volume) are exposed as `@WireletExpose` array getters so Kotlin can
/// rehydrate the inspector UI on open and reflect display state.
///
/// Sentinels (Wirelet has no `nil`): `tempoMultiplier`/`a4ReferenceHz` of `0` mean "no override".
@WireletObservable
@Observable
public final class ReaderPreferencesBridge {
    @ObservationIgnored private let store: ReaderPreferencesStore
    @ObservationIgnored private var scoreId = ""
    @ObservationIgnored private var prefs: ReaderPreferences {
        didSet { republish() }
    }

    public var state = ReaderPreferencesStateWire(
        staffSize: 14, honorLayoutBreaks: true, masterVolume: 1,
        tempoMultiplier: 0, a4ReferenceHz: 0, transposeSemitones: 0,
    )

    public init(store: ReaderPreferencesStore) {
        self.store = store
        prefs = ReaderPreferences(scoreItemID: ScoreItemID(), staffSize: 14, hiddenStaves: [])
    }

    // MARK: - Open / lifecycle

    /// Loads stored preferences for `scoreId`. When nothing is stored, seeds defaults (using the Reader's
    /// current global default staff size) and writes them through so the row exists for subsequent saves.
    @WireletExpose
    public func open(scoreId: String, defaultStaffSize: Double) {
        self.scoreId = scoreId
        let json = store.loadJSON(scoreId: scoreId)
        if let decoded = ReaderPreferencesReducer.decode(json) {
            prefs = decoded
        } else {
            prefs = ReaderPreferences(scoreItemID: ScoreItemID(), staffSize: defaultStaffSize, hiddenStaves: [])
            store.saveJSON(scoreId: scoreId, json: ReaderPreferencesReducer.encode(prefs))
        }
    }

    // MARK: - Scalar mutators (Kotlin -> Swift)

    @WireletExpose
    public func setStaffSize(value: Double) {
        mutate { ReaderPreferencesReducer.setStaffSize($0, value) }
    }

    @WireletExpose
    public func setHonorLayoutBreaks(value: Bool) {
        mutate { ReaderPreferencesReducer.setHonorLayoutBreaks($0, value) }
    }

    @WireletExpose
    public func setMasterVolume(value: Double) {
        mutate { ReaderPreferencesReducer.setMasterVolume($0, value) }
    }

    @WireletExpose
    public func setTempoMultiplier(value: Double) {
        mutate { ReaderPreferencesReducer.setTempoMultiplier($0, value) }
    }

    @WireletExpose
    public func setA4ReferenceHz(value: Double) {
        mutate { ReaderPreferencesReducer.setA4ReferenceHz($0, value) }
    }

    @WireletExpose
    public func setTranspose(value: Int32) {
        mutate { ReaderPreferencesReducer.setTranspose($0, Int(value)) }
    }

    // MARK: - Per-staff mutators (Kotlin -> Swift)

    @WireletExpose
    public func setStaffHidden(part: Int32, staff: Int32, hidden: Bool) {
        mutate { ReaderPreferencesReducer.setStaffHidden($0, part: Int(part), staff: Int(staff), hidden: hidden) }
    }

    @WireletExpose
    public func setClef(part: Int32, staff: Int32, rawType: String) {
        mutate { ReaderPreferencesReducer.setClef($0, part: Int(part), staff: Int(staff), rawType: rawType) }
    }

    @WireletExpose
    public func setStaffProgram(part: Int32, staff: Int32, program: Int32) {
        mutate {
            ReaderPreferencesReducer.setStaffProgram($0, part: Int(part), staff: Int(staff), program: Int(program))
        }
    }

    @WireletExpose
    public func setStaffVolume(part: Int32, staff: Int32, volume: Double) {
        mutate { ReaderPreferencesReducer.setStaffVolume($0, part: Int(part), staff: Int(staff), volume: volume) }
    }

    // MARK: - Per-staff list getters (Swift -> Kotlin, for restore-on-open + display reflection)

    @WireletExpose
    public func hiddenStaves() -> [HiddenStaffEntryWire] {
        prefs.hiddenStaves.map {
            HiddenStaffEntryWire(partIndex: Int32($0.partIndex), staffIndexInPart: Int32($0.staffIndexInPart))
        }
    }

    @WireletExpose
    public func clefOverrides() -> [ClefOverrideEntryWire] {
        prefs.staffClefOverrides.map {
            ClefOverrideEntryWire(
                partIndex: Int32($0.key.partIndex),
                staffIndexInPart: Int32($0.key.staffIndexInPart),
                rawType: $0.value,
            )
        }
    }

    @WireletExpose
    public func programOverrides() -> [ProgramOverrideWire] {
        prefs.staffProgramOverrides.map {
            ProgramOverrideWire(
                partIndex: Int32($0.key.partIndex),
                staffIndexInPart: Int32($0.key.staffIndexInPart),
                program: Int32($0.value),
            )
        }
    }

    @WireletExpose
    public func volumeOverrides() -> [VolumeOverrideWire] {
        prefs.staffVolumeOverrides.map {
            VolumeOverrideWire(
                partIndex: Int32($0.key.partIndex),
                staffIndexInPart: Int32($0.key.staffIndexInPart),
                volume: $0.value,
            )
        }
    }

    // MARK: - Private

    private func mutate(_ transform: (ReaderPreferences) -> ReaderPreferences) {
        prefs = transform(prefs)
        store.saveJSON(scoreId: scoreId, json: ReaderPreferencesReducer.encode(prefs))
    }

    private func republish() {
        state = ReaderPreferencesStateWire(
            staffSize: prefs.staffSize,
            honorLayoutBreaks: prefs.honorLayoutBreaks,
            masterVolume: prefs.masterVolume,
            tempoMultiplier: prefs.tempoMultiplier ?? 0,
            a4ReferenceHz: prefs.a4ReferenceHz ?? 0,
            transposeSemitones: Int32(prefs.transposeSemitones),
        )
    }
}
