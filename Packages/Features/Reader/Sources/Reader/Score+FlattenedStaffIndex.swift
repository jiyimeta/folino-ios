import SheetMusicCore

extension Score {
    /// Position of the staff at `address` in `allStaves`, i.e. the flat index the playback engine uses to address
    /// voices. Returns nil when the address isn't part of the score.
    func flattenedStaffIndex(of address: StaffAddress) -> Int? {
        allStaves.firstIndex { $0.address == address }
    }
}
