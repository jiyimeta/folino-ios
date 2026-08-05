import Domain
@testable import FolinoLibraryJNI
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
