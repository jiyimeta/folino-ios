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
    ///
    /// `BracketItem`s anchor on the topmost staff of their group with a
    /// `span` count of staves below them (see `BracketItem` in
    /// SheetMusicCore). Naively dropping staves loses the bracket when
    /// the anchor is hidden and miscounts the span when an interior
    /// staff is hidden, so brackets are re-anchored here against the
    /// surviving staves before the layout engine sees them.
    func filtered(hidingStaves addresses: Set<StaffAddress>) -> Score {
        guard !addresses.isEmpty else { return self }
        var copy = self
        var newParts: [Part] = []
        for (partIndex, part) in parts.enumerated() {
            let keep: [Bool] = part.staves.indices.map { staffIndex in
                !addresses.contains(StaffAddress(
                    partIndex: partIndex, staffIndexInPart: staffIndex,
                ))
            }
            guard keep.contains(true) else { continue }

            var keptStaves: [Staff] = []
            var newIndexFor: [Int: Int] = [:]
            for (origIndex, staff) in part.staves.enumerated() where keep[origIndex] {
                newIndexFor[origIndex] = keptStaves.count
                var stripped = staff
                stripped.brackets = []
                keptStaves.append(stripped)
            }

            for (origIndex, staff) in part.staves.enumerated() {
                for bracket in staff.brackets {
                    let endOriginal = min(
                        origIndex + bracket.span - 1,
                        part.staves.count - 1,
                    )
                    let surviving = (origIndex ... endOriginal).filter { keep[$0] }
                    guard let firstOriginal = surviving.first,
                          let anchor = newIndexFor[firstOriginal]
                    else { continue }
                    var rebased = bracket
                    rebased.span = surviving.count
                    keptStaves[anchor].brackets.append(rebased)
                }
            }

            var newPart = part
            newPart.staves = keptStaves
            newParts.append(newPart)
        }
        copy.parts = newParts
        return copy
    }
}
