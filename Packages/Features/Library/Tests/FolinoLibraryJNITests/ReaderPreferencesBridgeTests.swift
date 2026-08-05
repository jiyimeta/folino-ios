import Domain
@testable import FolinoLibraryJNI
import Foundation
import Testing

/// In-memory stand-in for the Kotlin/Room blob backend. Counts writes so the "an untouched score is not persisted"
/// rule can be asserted directly.
private final class FakeReaderPreferencesStore: ReaderPreferencesStore {
    var blobs: [String: String] = [:]
    private(set) var saveCount = 0

    func loadJSON(scoreId: String) -> String {
        blobs[scoreId] ?? ""
    }

    func saveJSON(scoreId: String, json: String) {
        saveCount += 1
        blobs[scoreId] = json
    }
}

/// A pre-`schemaVersion` blob, built by encoding a current one and dropping the marker key. Goes through
/// `JSONSerialization` rather than string surgery because `JSONEncoder` does not fix key order. The result is
/// asserted to actually read as legacy — otherwise a silent no-op would leave a v2 blob behind and quietly stop
/// testing the legacy path. Shared with `AnalyticsBridgeScorePrefsTests`, which exercises the same demotion rule
/// from the analytics side.
func legacyReaderPreferencesBlob(_ prefs: ReaderPreferences) -> String {
    let encoded = Data(ReaderPreferencesReducer.encode(prefs).utf8)
    var object = ((try? JSONSerialization.jsonObject(with: encoded)) as? [String: Any]) ?? [:]
    object.removeValue(forKey: "schemaVersion")
    let stripped = (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
    let legacy = String(bytes: stripped, encoding: .utf8) ?? ""
    #expect(ReaderPreferencesReducer.isLegacyBlob(legacy))
    return legacy
}

struct ReaderPreferencesBridgeTests {
    private func saved(_ store: FakeReaderPreferencesStore, _ scoreId: String) -> ReaderPreferences? {
        ReaderPreferencesReducer.decode(store.loadJSON(scoreId: scoreId))
    }

    /// A row that says nothing but "defaults" carries no information, and writing one on first open would make every
    /// opened score look touched. The seed is held in memory; the first real mutation persists it.
    @Test func `opening a score with nothing stored writes no row`() {
        let store = FakeReaderPreferencesStore()
        let bridge = ReaderPreferencesBridge(store: store)
        bridge.open(scoreId: "s1", defaultStaffSize: 20)
        #expect(store.saveCount == 0)
        #expect(store.loadJSON(scoreId: "s1").isEmpty)
    }

    /// The wire is a resolved scalar projection for Compose: Kotlin never sees `nil`, so every untouched field must
    /// come out of the bridge as the current default — staff size against the default the Reader passed to `open`.
    @Test func `the wire projection resolves untouched scalars to defaults`() {
        let store = FakeReaderPreferencesStore()
        let bridge = ReaderPreferencesBridge(store: store)
        bridge.open(scoreId: "s1", defaultStaffSize: 20)
        #expect(bridge.state.staffSize == 20)
        #expect(bridge.state.honorLayoutBreaks == ReaderPreferences.defaultHonorLayoutBreaks)
        #expect(bridge.state.masterVolume == ReaderPreferences.defaultMasterVolume)
        #expect(bridge.state.transposeSemitones == Int32(ReaderPreferences.defaultTransposeSemitones))
        #expect(bridge.state.tempoMultiplier == 0) // sentinel: no override
        #expect(bridge.state.a4ReferenceHz == 0) // sentinel: inherit global
    }

    /// The failure this plan exists to prevent: a save triggered by one setting must not materialize numbers for the
    /// settings the user never touched.
    @Test func `a mutation on an untouched score does not materialize the other scalars`() {
        let store = FakeReaderPreferencesStore()
        let bridge = ReaderPreferencesBridge(store: store)
        bridge.open(scoreId: "s1", defaultStaffSize: 20)
        bridge.setMasterVolume(value: 0.5)
        let persisted = saved(store, "s1")
        #expect(persisted?.masterVolume == 0.5)
        #expect(persisted?.staffSize == nil)
        #expect(persisted?.honorLayoutBreaks == nil)
        #expect(persisted?.transposeSemitones == nil)
    }

    /// `.some(default)` means "explicitly chosen" and must survive the load → project → mutate → save round-trip.
    @Test func `an explicitly chosen default survives reopening`() {
        let store = FakeReaderPreferencesStore()
        let first = ReaderPreferencesBridge(store: store)
        first.open(scoreId: "s1", defaultStaffSize: 20)
        first.setMasterVolume(value: ReaderPreferences.defaultMasterVolume)
        first.setTranspose(value: 0)

        let second = ReaderPreferencesBridge(store: store)
        second.open(scoreId: "s1", defaultStaffSize: 20)
        second.setStaffHidden(part: 0, staff: 0, hidden: true)
        let persisted = saved(store, "s1")
        #expect(persisted?.masterVolume == ReaderPreferences.defaultMasterVolume)
        #expect(persisted?.transposeSemitones == 0)
    }

    /// Reset parity with iOS (`MasterVolumeModel.resetValue` / `TransposeModel.reset`): a reset means "untouched",
    /// not "explicitly the default".
    @Test func `clearing a scalar persists it as untouched`() {
        let store = FakeReaderPreferencesStore()
        let bridge = ReaderPreferencesBridge(store: store)
        bridge.open(scoreId: "s1", defaultStaffSize: 20)
        bridge.setMasterVolume(value: 0.5)
        bridge.setTranspose(value: 3)
        bridge.clearMasterVolume()
        bridge.clearTranspose()
        let persisted = saved(store, "s1")
        #expect(persisted?.masterVolume == nil)
        #expect(persisted?.transposeSemitones == nil)
        // Compose still sees resolved scalars.
        #expect(bridge.state.masterVolume == ReaderPreferences.defaultMasterVolume)
        #expect(bridge.state.transposeSemitones == Int32(ReaderPreferences.defaultTransposeSemitones))
    }

    /// The Android half of the "untouched is `nil`" migration. Domain demotes a legacy `staffSize` only when it
    /// equals iOS's frozen `14`; Android's removed eager seed wrote the *global* default instead (initially 28), so
    /// without this every score an Android user has ever opened would report an explicitly configured staff size
    /// forever.
    @Test func `a legacy blob whose staff size is the global default decodes as untouched`() {
        let store = FakeReaderPreferencesStore()
        store.blobs["s1"] = legacyReaderPreferencesBlob(
            ReaderPreferences(scoreItemID: ScoreItemID(), staffSize: 28, hiddenStaves: []),
        )
        let bridge = ReaderPreferencesBridge(store: store)
        bridge.open(scoreId: "s1", defaultStaffSize: 28)
        // No user-visible change: the cleared value resolves back to the same global.
        #expect(bridge.state.staffSize == 28)
        bridge.setMasterVolume(value: 0.5) // force the first save so the stored value can be inspected
        #expect(saved(store, "s1")?.staffSize == nil)
    }

    /// The other half: a legacy staff size the user actually chose differs from the global and must be kept.
    @Test func `a legacy blob whose staff size differs from the global default keeps it`() {
        let store = FakeReaderPreferencesStore()
        store.blobs["s1"] = legacyReaderPreferencesBlob(
            ReaderPreferences(scoreItemID: ScoreItemID(), staffSize: 18, hiddenStaves: []),
        )
        let bridge = ReaderPreferencesBridge(store: store)
        bridge.open(scoreId: "s1", defaultStaffSize: 28)
        #expect(bridge.state.staffSize == 18)
        bridge.setMasterVolume(value: 0.5)
        #expect(saved(store, "s1")?.staffSize == 18)
    }

    /// A v2 blob is authoritative: it was written under "untouched is `nil`", so a stored value equal to the global
    /// is a deliberate choice and must survive.
    @Test func `a current blob keeps a staff size equal to the global default`() {
        let store = FakeReaderPreferencesStore()
        store.blobs["s1"] = ReaderPreferencesReducer.encode(
            ReaderPreferences(scoreItemID: ScoreItemID(), staffSize: 28, hiddenStaves: []),
        )
        let bridge = ReaderPreferencesBridge(store: store)
        bridge.open(scoreId: "s1", defaultStaffSize: 28)
        bridge.setMasterVolume(value: 0.5)
        #expect(saved(store, "s1")?.staffSize == 28)
    }

    /// Seeding authored visibility on a score that authored nothing hidden must not write a row either — and must
    /// not leave a staff size behind.
    @Test func `seeding authored hidden staves persists only what the score authored`() {
        let store = FakeReaderPreferencesStore()
        let bridge = ReaderPreferencesBridge(store: store)
        bridge.open(scoreId: "s1", defaultStaffSize: 20)
        bridge.seedAuthoredHidden(staves: [])
        #expect(store.saveCount == 0)

        bridge.seedAuthoredHidden(staves: [HiddenStaffEntryWire(partIndex: 1, staffIndexInPart: 0)])
        let persisted = saved(store, "s1")
        #expect(persisted?.hiddenStaves == [StaffAddress(partIndex: 1, staffIndexInPart: 0)])
        #expect(persisted?.authoredHiddenStaves == [StaffAddress(partIndex: 1, staffIndexInPart: 0)])
        #expect(persisted?.hasSeededAuthoredVisibility == true)
        #expect(persisted?.staffSize == nil)
    }
}
