import SheetMusicCore

extension Score {
    /// Staff addresses of every part the file authored as hidden — i.e. parts
    /// whose `Part.isVisibleInScore` is `false`, MuseScore's
    /// `<Part><show>0</show>` "hide instrument in the main score" flag.
    ///
    /// `<show>` is a per-part flag, so a hidden part contributes *all* of its
    /// staves. Hosts seed these into the Reader's hidden-staff set so an
    /// authored-hidden instrument opens hidden by default while staying
    /// revealable (and audible — hiding is display-only). Shared by both the
    /// iOS and Android readers so the derivation stays identical.
    public var authoredHiddenStaffAddresses: Set<StaffAddress> {
        var hidden: Set<StaffAddress> = []
        for (partIndex, part) in parts.enumerated() where !part.isVisibleInScore {
            for staffIndexInPart in part.staves.indices {
                hidden.insert(StaffAddress(
                    partIndex: partIndex, staffIndexInPart: staffIndexInPart,
                ))
            }
        }
        return hidden
    }
}
