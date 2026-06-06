import SheetMusicCore

extension Score {
    /// When the engine emits a `.item(id)` cursor:
    ///
    /// * if the cursor's staff is hidden, translate to `.beat` so the
    ///   renderer falls back to interpolated X against the surviving
    ///   columns;
    /// * if the staff is visible but its full-score address differs
    ///   from its filtered address (an earlier staff in the same part
    ///   is hidden, or an earlier part is fully hidden), re-stamp the
    ///   `NoteID` / `RestID` with the filtered address so
    ///   `PlaybackCursorView.itemFrame`'s `LayoutDocument` lookup —
    ///   keyed by filtered addresses — can find it.
    ///
    /// `.beat` cursors and visible-staff `.item` values whose full and filtered addresses already match pass through
    /// unchanged.
    func translateCursorForHiddenStaves(
        _ cursor: ScoreCursor?,
        hiddenStaves hidden: Set<StaffAddress>,
    ) -> ScoreCursor? {
        guard let cursor else { return nil }
        guard !hidden.isEmpty,
              case let .item(id) = cursor
        else { return cursor }
        if hidden.contains(id.staff) {
            guard let tick = resolveTickInMeasure(for: id) else { return cursor }
            return .beat(measureIndex: id.measureIndex, tickInMeasure: tick)
        }
        guard let filteredStaff = filterStaffAddress(id.staff, hidingStaves: hidden),
              filteredStaff != id.staff
        else { return cursor }
        switch id {
        case let .note(noteID):
            return .item(.note(NoteID(
                staff: filteredStaff,
                measureIndex: noteID.measureIndex,
                voiceIndex: noteID.voiceIndex,
                elementIndex: noteID.elementIndex,
                noteIndexInChord: noteID.noteIndexInChord,
            )))
        case let .rest(restID):
            return .item(.rest(RestID(
                staff: filteredStaff,
                measureIndex: restID.measureIndex,
                voiceIndex: restID.voiceIndex,
                elementIndex: restID.elementIndex,
            )))
        case .tuplet, .clef:
            return cursor
        }
    }
}
