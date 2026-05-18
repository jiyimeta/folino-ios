import SheetMusicCore

extension Score {
    /// Inverse of the part/staff renumbering performed by `filtered(hidingStaves:)`: given a `StaffAddress` produced
    /// against the *filtered* score, returns the corresponding address in this (unfiltered) score, or `nil` when the
    /// filtered address can't be located under the current visibility.
    ///
    /// `StaffAddress` is purely positional — `(partIndex, staffIndexInPart)` — and `filtered(hidingStaves:)` rebuilds
    /// parts dropping fully-hidden ones and reindexes the surviving staves within each remaining part. The Reader's
    /// `LayoutDocument` is built from the filtered score, so `NoteID`s / `RestID`s emitted by `nearestCursor` carry
    /// filtered addresses. The playback engine's timeline is keyed by the full-score address. This helper bridges that
    /// gap before a tap-derived cursor is forwarded to the controller.
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

    /// Forward direction of `unfilterStaffAddress`: given a full-score `StaffAddress`, return the corresponding address
    /// in the filtered score, or `nil` when the staff is itself hidden (or its enclosing part is fully hidden).
    ///
    /// `PlaybackEngine`'s timeline is keyed by full-score addresses, but the Reader's `LayoutDocument` is built from
    /// the filtered score and stamps filtered addresses onto its `NoteID` / `RestID` keys. The cursor has to be
    /// re-stamped before the renderer can locate it — without this, a cursor emitted on a visible staff whose full
    /// address differs from its filtered address (any time an earlier staff in the same part is hidden, or an earlier
    /// part is fully hidden) silently fails the layout lookup and disappears.
    func filterStaffAddress(
        _ full: StaffAddress,
        hidingStaves hidden: Set<StaffAddress>,
    ) -> StaffAddress? {
        guard !hidden.isEmpty else { return full }
        guard !hidden.contains(full) else { return nil }
        var newPartIdx = 0
        for (origPartIdx, part) in parts.enumerated() {
            let surviving = part.staves.indices.filter { sIdx in
                !hidden.contains(StaffAddress(
                    partIndex: origPartIdx, staffIndexInPart: sIdx,
                ))
            }
            guard !surviving.isEmpty else { continue }
            if origPartIdx == full.partIndex {
                guard let newStaffIdx = surviving.firstIndex(
                    of: full.staffIndexInPart,
                ) else { return nil }
                return StaffAddress(
                    partIndex: newPartIdx,
                    staffIndexInPart: newStaffIdx,
                )
            }
            newPartIdx += 1
        }
        return nil
    }
}
