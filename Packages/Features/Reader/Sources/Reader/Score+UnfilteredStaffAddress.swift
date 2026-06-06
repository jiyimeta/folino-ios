import SheetMusicCore

extension Score {
    /// Given a full-score `StaffAddress`, return the corresponding address in the filtered score, or `nil` when the
    /// staff is itself hidden (or its enclosing part is fully hidden).
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
