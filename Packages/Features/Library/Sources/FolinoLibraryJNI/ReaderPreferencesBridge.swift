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

    /// The Reader's current global default staff size, handed in by `open`. Retained because `staffSize` is Optional
    /// on the model (`nil` = the user never chose one) while the wire is a resolved scalar — this is the value the
    /// projection resolves against. Kept in sync only by `open`, which is also where the Reader learns it.
    @ObservationIgnored private var openDefaultStaffSize: Double = 14
    /// The same, for the break policy. Both defaults are device-class-dependent on Android
    /// (`ReaderDeviceDefaults.kt`), which is why neither can be a constant here.
    @ObservationIgnored private var openDefaultHonorLayoutBreaks = true

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
        // Placeholder until `open` runs. It carries no user choices, so every scalar stays untouched.
        prefs = ReaderPreferences(scoreItemID: ScoreItemID(), hiddenStaves: [])
    }

    // MARK: - Open / lifecycle

    /// Loads stored preferences for `scoreId`. When nothing is stored, seeds an untouched value in memory and does
    /// NOT write it through: a row that says nothing but "defaults" carries no information, and persisting one on
    /// every open would make every opened score look like one the user configured. The first real mutation persists
    /// it via `mutate`.
    ///
    /// `defaultStaffSize` and `defaultHonorLayoutBreaks` are the Reader's current device-class defaults. Neither is
    /// stored into the preferences — they are retained as the values the wire projection resolves the matching
    /// untouched fields against. The legacy demotion does not use them: it compares against the frozen seed Android
    /// actually wrote (see `ReaderPreferencesReducer.decode(_:)`).
    @WireletExpose
    public func open(scoreId: String, defaultStaffSize: Double, defaultHonorLayoutBreaks: Bool) {
        self.scoreId = scoreId
        openDefaultStaffSize = defaultStaffSize
        openDefaultHonorLayoutBreaks = defaultHonorLayoutBreaks
        let json = store.loadJSON(scoreId: scoreId)
        if let decoded = ReaderPreferencesReducer.decode(json) {
            prefs = decoded
        } else {
            prefs = ReaderPreferences(scoreItemID: ScoreItemID(), hiddenStaves: [])
        }
    }

    /// Reconciles the score's authored-hidden staves (`<Part><show>0</show>`, from the ssm `PartWire`) into the loaded
    /// preferences once. Kotlin calls this after the parsed score's parts arrive — the point where authored visibility
    /// becomes known — since `open` fires before the score parses. Uses the shared
    /// `ReaderPreferences.reconcilingAuthoredHidden` so it matches iOS exactly: a not-yet-seeded row gets the
    /// authored-hidden staves unioned in and is marked seeded; an already-seeded row whose recorded authored set no
    /// longer matches the score's has just that provenance refreshed and rewritten, with `hiddenStaves` left alone so
    /// staves the user revealed stay revealed on reopen; a row already in agreement is returned unchanged and not
    /// written.
    ///
    /// Re-firing is safe only *given the caller contract* on `reconcilingAuthoredHidden`: because the refresh branch
    /// rewrites the authored set to whatever it is handed, this is idempotent for the same authored set, not for any
    /// argument. Kotlin must not call it before the parse has produced parts — `ReaderScreen.kt:562-563` enforces
    /// that with `if (mixerParts.isNotEmpty())`, and that guard is load-bearing.
    @WireletExpose
    public func seedAuthoredHidden(staves: [HiddenStaffEntryWire]) {
        let authored = Set(staves.map {
            StaffAddress(partIndex: Int($0.partIndex), staffIndexInPart: Int($0.staffIndexInPart))
        })
        let (resolved, shouldPersist) = ReaderPreferences.reconcilingAuthoredHidden(
            stored: prefs,
            authoredHiddenStaves: authored,
            scoreItemID: prefs.scoreItemID,
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

    // MARK: - Reset verbs (Kotlin -> Swift)

    /// Reset affordance for staff size (the slider's double-tap). Writes "the user never chose one" rather than a
    /// number, so the score follows the device-class default. Its predecessor wrote a hardcoded `28.0`.
    @WireletExpose
    public func clearStaffSize() {
        mutate { ReaderPreferencesReducer.clearStaffSize($0) }
    }

    /// Reset affordance for master volume (the slider's double-tap). Writes "the user never chose one" rather than
    /// an explicit unity, matching iOS `MasterVolumeModel.resetValue` — otherwise a reset on Android would report the
    /// score as one the user deliberately set to the default.
    @WireletExpose
    public func clearMasterVolume() {
        mutate { ReaderPreferencesReducer.clearMasterVolume($0) }
    }

    /// Reset affordance for transposition (tap on the signed readout). Writes "untouched" rather than an explicit
    /// `0`, matching iOS `TransposeModel.reset`. Stepping to `0` with the ± buttons still records an explicit `0`.
    @WireletExpose
    public func clearTranspose() {
        mutate { ReaderPreferencesReducer.clearTranspose($0) }
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

    /// Projects `prefs` to the Compose-facing wire. This is the boundary where "untouched" is resolved: the wire is
    /// a resolved scalar projection, so Kotlin never sees the Optional — an untouched field comes out as the current
    /// default, read through the model's `effective…` accessors. The resolution goes ONLY this way; nothing here
    /// writes back, so a projected default never becomes a stored one.
    private func republish() {
        revision &+= 1
        state = ReaderPreferencesStateWire(
            staffSize: prefs.effectiveStaffSize(default: openDefaultStaffSize),
            honorLayoutBreaks: prefs.effectiveHonorLayoutBreaks(default: openDefaultHonorLayoutBreaks),
            masterVolume: prefs.effectiveMasterVolume,
            tempoMultiplier: prefs.tempoMultiplier ?? 0,
            a4ReferenceHz: prefs.a4ReferenceHz ?? 0,
            transposeSemitones: Int32(prefs.effectiveTransposeSemitones),
            revision: revision,
        )
    }
}
