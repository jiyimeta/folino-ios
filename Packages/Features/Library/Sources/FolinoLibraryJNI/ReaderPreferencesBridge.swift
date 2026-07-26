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

    /// Monotonic change token folded into `state` on each republish. The per-staff collections (hidden / clef /
    /// program / volume) are not part of `ReaderPreferencesStateWire`, so a collection-only mutation would
    /// otherwise rebuild an `Equatable`-equal wire that the Kotlin `MutableStateFlow` dedups — leaving the
    /// Compose consumer's `remember(state) { vm.hiddenStaves() }` stale until the screen is recreated. Bumping
    /// this guarantees a distinct value so the state always ticks. See `ReaderPreferencesStateWire`.
    @ObservationIgnored private var revision: Int32 = 0

    // The explicit type annotation is load-bearing: the wirelet observable schema parser only picks up stored
    // properties that carry an explicit `: Type`, so the generated Kotlin view model emits the `state` StateFlow.
    // Both SwiftFormat and SwiftLint would otherwise strip it as redundant.
    // swiftformat:disable redundantType
    // swiftlint:disable:next redundant_type_annotation
    public var state: ReaderPreferencesStateWire = ReaderPreferencesStateWire(
        staffSize: 14, honorLayoutBreaks: true, masterVolume: 1,
        tempoMultiplier: 0, a4ReferenceHz: 0, transposeSemitones: 0,
    )
    // swiftformat:enable redundantType

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

    /// Reconciles the score's authored-hidden staves (`<Part><show>0</show>`, from the ssm `PartWire`) into the loaded
    /// preferences once. Kotlin calls this after the parsed score's parts arrive — the point where authored visibility
    /// becomes known — since `open` fires before the score parses. Uses the shared
    /// `ReaderPreferences.reconcilingAuthoredHidden` so it matches iOS exactly: a not-yet-seeded row gets the authored-
    /// hidden staves unioned in and is marked seeded; an already-seeded row (or one with nothing authored-hidden) is
    /// left untouched, so staves the user reveals stay revealed on reopen.
    @WireletExpose
    public func seedAuthoredHidden(staves: [HiddenStaffEntryWire]) {
        let authored = Set(staves.map {
            StaffAddress(partIndex: Int($0.partIndex), staffIndexInPart: Int($0.staffIndexInPart))
        })
        let (resolved, shouldPersist) = ReaderPreferences.reconcilingAuthoredHidden(
            stored: prefs,
            authoredHiddenStaves: authored,
            scoreItemID: prefs.scoreItemID,
            defaultStaffSize: prefs.staffSize,
        )
        guard shouldPersist else { return }
        prefs = resolved
        store.saveJSON(scoreId: scoreId, json: ReaderPreferencesReducer.encode(resolved))
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
        revision &+= 1
        state = ReaderPreferencesStateWire(
            staffSize: prefs.staffSize,
            honorLayoutBreaks: prefs.honorLayoutBreaks,
            masterVolume: prefs.masterVolume,
            tempoMultiplier: prefs.tempoMultiplier ?? 0,
            a4ReferenceHz: prefs.a4ReferenceHz ?? 0,
            transposeSemitones: Int32(prefs.transposeSemitones),
            revision: revision,
        )
    }
}
