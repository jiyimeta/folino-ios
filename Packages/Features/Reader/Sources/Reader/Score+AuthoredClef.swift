import SheetMusicCore

extension Score {
    /// Authored opening clef rawType for the staff at `address`: the explicit measure-0 clef when one exists, otherwise
    /// the staff's `defaultClefType`. Returns nil when the address points outside the score or the staff declares no
    /// default. Callers (e.g. the Reader's clef-override picker) layer their own fallback on top.
    func authoredClef(at address: StaffAddress) -> String? {
        guard let staff = self[address] else { return nil }
        if let first = staff.measures.first?.voices.first?.elements.first,
           case let .clef(c) = first
        {
            return c.concertClefType
        }
        return staff.defaultClefType
    }
}
