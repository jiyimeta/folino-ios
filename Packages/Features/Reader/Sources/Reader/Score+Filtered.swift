import SheetMusicCore

extension Score {
    /// Returns a copy of the score with the staves at the given addresses
    /// removed from each `Part.staves`. Parts left without any visible
    /// staff are dropped entirely so labels and brackets do not render
    /// against an empty group.
    ///
    /// Indexing is positional: a `StaffAddress(partIndex, staffIndexInPart)`
    /// resolves to `parts[partIndex].staves[staffIndexInPart]` on the
    /// pre-filter score.
    func filtered(hidingStaves addresses: Set<StaffAddress>) -> Score {
        guard !addresses.isEmpty else { return self }
        var copy = self
        var newParts: [Part] = []
        for (partIndex, part) in parts.enumerated() {
            var keptStaves: [Staff] = []
            for (staffIndex, staff) in part.staves.enumerated() {
                let address = StaffAddress(partIndex: partIndex, staffIndexInPart: staffIndex)
                if !addresses.contains(address) {
                    keptStaves.append(staff)
                }
            }
            if !keptStaves.isEmpty {
                var newPart = part
                newPart.staves = keptStaves
                newParts.append(newPart)
            }
        }
        copy.parts = newParts
        return copy
    }
}
