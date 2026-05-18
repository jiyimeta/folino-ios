import SheetMusicCore

extension Score {
    /// Hash that captures every staff's opening clef state — both the `defaultClefType` and the first measure-0 clef
    /// element's `concertClefType` / `transposingClefType`. `VerticalScoreContainer` and `HorizontalScoreContainer`
    /// fold this into their `.task(id:)` keys so a clef override change (which `Score.applying(clefOverrides:)` applies
    /// as a field-level edit without altering parts.count or totalStaffCount) still triggers a relayout. Without this,
    /// the structural-only signature wouldn't change and the engraved view would keep showing the previous clef until
    /// something else (a staff hide/show, an app foreground cycle) forced a rebuild.
    var openingClefSignature: Int {
        var hasher = Hasher()
        for part in parts {
            for staff in part.staves {
                hasher.combine(staff.defaultClefType)
                if case let .clef(clef) = staff.measures.first?.voices.first?.elements.first {
                    hasher.combine(clef.concertClefType)
                    hasher.combine(clef.transposingClefType)
                }
            }
        }
        return hasher.finalize()
    }
}
