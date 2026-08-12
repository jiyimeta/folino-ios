import Domain
@testable import Reader
import SheetMusicCore
import Testing

/// `ReaderViewModel.collapsingToPartsFirstStaff` is the interim adapter `wireMixerModel()` uses to persist the
/// still-staff-addressed `PlaybackMixerModel` into `ReaderPreferences`'s now-strip-keyed overrides (Task 9 deletes
/// this whole conversion once the mixer model itself is re-keyed). A part with more than one staff cannot keep both
/// staves' independently-set values in a strip-keyed dictionary, so the collapse must pick one — deterministically,
/// matching the LOWEST `staffIndexInPart`, the same choice `PlaybackMixerModel.sync(from:)` already treats as
/// canonical on the way in. Before this pin, the collapse used `Dictionary`'s `uniquingKeysWith` with unspecified
/// iteration order, so which staff survived depended on the process's hash seed — the same user action could
/// persist a different staff's value between sessions.
@MainActor
struct ReaderViewModelMixerCollapseTests {
    private let topStaff = StaffAddress(partIndex: 0, staffIndexInPart: 0)
    private let bottomStaff = StaffAddress(partIndex: 0, staffIndexInPart: 1)
    private let strip = MixerStripID(partIndex: 0, instrumentOrdinal: 0)

    @Test func `a grand staff's two independently-set volumes collapse to the lower staff's value`() {
        let overrides: [StaffAddress: Double] = [topStaff: 0.4, bottomStaff: 0.9]

        let collapsed = ReaderViewModel.collapsingToPartsFirstStaff(overrides)

        #expect(collapsed == [strip: 0.4])
    }

    /// Same input, keys inserted in the opposite order — `Dictionary` does not preserve insertion order, but this
    /// pins that the result is independent of it either way, which is the property the arbitrary-order bug broke.
    @Test func `the result does not depend on which staff was inserted first`() {
        let overrides: [StaffAddress: Double] = [bottomStaff: 0.9, topStaff: 0.4]

        let collapsed = ReaderViewModel.collapsingToPartsFirstStaff(overrides)

        #expect(collapsed == [strip: 0.4])
    }

    @Test func `a single-staff part passes its one value through unchanged`() {
        let overrides: [StaffAddress: Int] = [topStaff: 40]

        let collapsed = ReaderViewModel.collapsingToPartsFirstStaff(overrides)

        #expect(collapsed == [strip: 40])
    }

    @Test func `distinct parts collapse independently`() {
        let otherPartFirstStaff = StaffAddress(partIndex: 1, staffIndexInPart: 0)
        let overrides: [StaffAddress: Double] = [topStaff: 0.4, bottomStaff: 0.9, otherPartFirstStaff: 0.6]

        let collapsed = ReaderViewModel.collapsingToPartsFirstStaff(overrides)

        #expect(collapsed == [
            strip: 0.4,
            MixerStripID(partIndex: 1, instrumentOrdinal: 0): 0.6,
        ])
    }

    @Test func `empty overrides collapse to empty`() {
        let overrides: [StaffAddress: Double] = [:]

        #expect(ReaderViewModel.collapsingToPartsFirstStaff(overrides).isEmpty)
    }
}
