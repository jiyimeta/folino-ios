import SheetMusicCore

extension Score {
    /// Inverse of the part/staff renumbering performed by
    /// `filtered(hidingStaves:)`: given a `StaffAddress` produced against
    /// the *filtered* score, returns the corresponding address in this
    /// (unfiltered) score, or `nil` when the filtered address can't be
    /// located under the current visibility.
    ///
    /// `StaffAddress` is purely positional — `(partIndex,
    /// staffIndexInPart)` — and `filtered(hidingStaves:)` rebuilds parts
    /// dropping fully-hidden ones and reindexes the surviving staves
    /// within each remaining part. The Reader's `LayoutDocument` is
    /// built from the filtered score, so `NoteID`s / `RestID`s emitted
    /// by `nearestCursor` carry filtered addresses. The playback
    /// engine's timeline is keyed by the full-score address. This
    /// helper bridges that gap before a tap-derived cursor is forwarded
    /// to the controller.
    func unfilterStaffAddress(
        _ filtered: StaffAddress,
        hidingStaves hidden: Set<StaffAddress>,
    ) -> StaffAddress? {
        guard !hidden.isEmpty else { return filtered }
        var newPartIdx = 0
        for (origPartIdx, part) in parts.enumerated() {
            let surviving = part.staves.indices.filter { sIdx in
                !hidden.contains(StaffAddress(
                    partIndex: origPartIdx, staffIndexInPart: sIdx,
                ))
            }
            guard !surviving.isEmpty else { continue }
            if newPartIdx == filtered.partIndex {
                guard surviving.indices.contains(filtered.staffIndexInPart)
                else { return nil }
                return StaffAddress(
                    partIndex: origPartIdx,
                    staffIndexInPart: surviving[filtered.staffIndexInPart],
                )
            }
            newPartIdx += 1
        }
        return nil
    }
}
