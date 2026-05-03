import SheetMusicCore

extension Score {
    /// Returns a copy of the score with the given staff IDs removed from
    /// `staves` and from each `Part.staffDeclarations`. Parts left without
    /// any visible staff are dropped entirely so labels and brackets do
    /// not render against an empty group.
    ///
    /// `StaffDeclaration` is matched to its `StaffContent` by position —
    /// `Part.staffDeclarations[i]` corresponds to the `i`-th staff in
    /// `staves` belonging to that part. (This mirrors how MuseScore's
    /// MSCX serializer emits them.) If a future schema change breaks
    /// that assumption, this helper needs updating.
    func filtered(hidingStaffIDs ids: Set<Int>) -> Score {
        guard !ids.isEmpty else { return self }
        var copy = self
        copy.staves.removeAll { ids.contains($0.id) }

        // Build a map from staff ID to the index of its declaration
        // within its parent part. Walk parts in order, advancing a per-
        // part declaration cursor for every staff in `self.staves`.
        var declIndexByStaffID: [Int: (partIndex: Int, declIndex: Int)] = [:]
        var perPartCursor: [Int: Int] = [:]
        for partIndex in parts.indices {
            perPartCursor[partIndex] = 0
        }
        var nextPartCursor = 0
        for staff in staves {
            // Find the part that owns this staff: the next part whose
            // declarations cursor is still within bounds.
            while nextPartCursor < parts.count,
                  perPartCursor[nextPartCursor, default: 0]
                  >= parts[nextPartCursor].staffDeclarations.count
            {
                nextPartCursor += 1
            }
            guard nextPartCursor < parts.count else { break }
            let declIndex = perPartCursor[nextPartCursor, default: 0]
            declIndexByStaffID[staff.id] = (nextPartCursor, declIndex)
            perPartCursor[nextPartCursor, default: 0] += 1
        }

        var newParts: [Part] = []
        for (partIndex, part) in parts.enumerated() {
            var keptDeclarations: [StaffDeclaration] = []
            for (declIndex, decl) in part.staffDeclarations.enumerated() {
                let owningStaffID = staves
                    .first(where: {
                        declIndexByStaffID[$0.id]?.partIndex == partIndex
                            && declIndexByStaffID[$0.id]?.declIndex == declIndex
                    })?.id
                if let id = owningStaffID, !ids.contains(id) {
                    keptDeclarations.append(decl)
                } else if owningStaffID == nil {
                    // Defensive: declaration with no matching staff — keep it so we
                    // don't silently change Part shape.
                    keptDeclarations.append(decl)
                }
            }
            if !keptDeclarations.isEmpty {
                var newPart = part
                newPart.staffDeclarations = keptDeclarations
                newParts.append(newPart)
            }
        }
        copy.parts = newParts
        return copy
    }
}
