import SheetMusicCore

extension Score {
    /// GM bank declared for the part that owns `address`, or nil when the address points outside the score. All staves
    /// under a part share the part's instrument, so the staff index is ignored.
    func gmBank(at address: StaffAddress) -> Int? {
        guard parts.indices.contains(address.partIndex) else { return nil }
        return parts[address.partIndex].instrument.channel.bank
    }

    /// GM program declared for the part that owns `address`, or nil when the address points outside the score.
    func gmProgram(at address: StaffAddress) -> Int? {
        guard parts.indices.contains(address.partIndex) else { return nil }
        return parts[address.partIndex].instrument.channel.program
    }

    /// CC7 (Channel Volume) from the part's first channel, mapped from MIDI's 0…127 to the slider's 0…1. Returns nil
    /// when the score has no matching part — callers fall back to their own default. Mirrors `swift-sheet-music`'s
    /// `PlaybackEngine.initialStaffVolume`.
    func initialStaffVolume(at address: StaffAddress) -> Double? {
        guard parts.indices.contains(address.partIndex) else { return nil }
        let cc7 = parts[address.partIndex].instrument.channel.volume
        let clamped = max(0, min(127, cc7))
        return Double(clamped) / 127.0
    }
}
