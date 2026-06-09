import Foundation

/// A coordinate that uniquely identifies a chord inside an engraved score's layout. Used as the cursor position and as
/// the endpoints of A–B repeat ranges. The exact mapping to `SheetMusicLayout` cursor types is the Infrastructure
/// adapter's responsibility — Domain only stores integer indices.
public struct ChordPath: Hashable, Sendable, Codable {
    public let systemIndex: Int
    public let measureIndex: Int
    public let voiceIndex: Int
    public let chordIndex: Int

    public init(systemIndex: Int, measureIndex: Int, voiceIndex: Int, chordIndex: Int) {
        self.systemIndex = systemIndex
        self.measureIndex = measureIndex
        self.voiceIndex = voiceIndex
        self.chordIndex = chordIndex
    }
}

/// Mixer settings for one staff in the engraved score. `gmBank` follows the MIDI convention (0 = melodic, 128 = drum);
/// `gmProgram` is the General MIDI program number (0…127).
public struct StaffMixerState: Hashable, Sendable, Codable {
    public let staffIndex: Int
    public var volume: Double
    public var isMuted: Bool
    public var isSolo: Bool
    public var gmBank: Int
    public var gmProgram: Int

    public init(staffIndex: Int, volume: Double, isMuted: Bool, isSolo: Bool, gmBank: Int, gmProgram: Int) {
        self.staffIndex = staffIndex
        self.volume = min(max(volume, 0), 1)
        self.isMuted = isMuted
        self.isSolo = isSolo
        self.gmBank = max(0, gmBank)
        self.gmProgram = min(max(gmProgram, 0), 127)
    }
}

/// A loop range selected on the score. Both endpoints are inclusive.
public struct ABRepeatRange: Hashable, Sendable, Codable {
    public let start: ChordPath
    public let end: ChordPath

    public init(start: ChordPath, end: ChordPath) {
        self.start = start
        self.end = end
    }
}

/// Per-score playback preferences: mixer state, tempo multiplier, and any active A–B loop. Persisted alongside the
/// score item.
public struct PlaybackPreferences: Hashable, Sendable, Codable, Identifiable {
    public let id: PlaybackPreferencesID
    public let scoreItemID: ScoreItemID
    public var perStaff: [StaffMixerState]
    public var tempoMultiplier: Double
    public var abRepeat: ABRepeatRange?
    /// Master output volume seeded into the engine on load. `1.0` is unity; clamped to `[0, 3]` (300%). Mirrors
    /// `ReaderPreferences.masterVolume` — see there for the limiter rationale.
    public var masterVolume: Double
    /// A4 reference frequency in Hz seeded into the engine on load. Defaults to `440` (standard concert pitch).
    /// Clamped to `[A4Reference.minHz, A4Reference.maxHz]`. Mirrors `ReaderPreferences.a4ReferenceHz` but stores
    /// the resolved value (never `nil`) so the engine always has an explicit target.
    public var a4ReferenceHz: Double
    /// Transposition offset in semitones seeded into the engine on load. `0` means no transposition; clamped to
    /// `[-7, +7]`. Mirrors `ReaderPreferences.transposeSemitones` so a new score's `load(...)` always resets the
    /// engine to the correct offset rather than inheriting the previous score's value.
    public var transposeSemitones: Int

    public init(
        id: PlaybackPreferencesID = PlaybackPreferencesID(),
        scoreItemID: ScoreItemID,
        perStaff: [StaffMixerState],
        tempoMultiplier: Double,
        abRepeat: ABRepeatRange?,
        masterVolume: Double = 1.0,
        a4ReferenceHz: Double = 440,
        transposeSemitones: Int = 0,
    ) {
        self.id = id
        self.scoreItemID = scoreItemID
        self.perStaff = perStaff
        self.tempoMultiplier = min(max(tempoMultiplier, 0.5), 2.0)
        self.abRepeat = abRepeat
        self.masterVolume = min(max(masterVolume, 0), 3)
        self.a4ReferenceHz = A4Reference.clamp(a4ReferenceHz)
        self.transposeSemitones = min(max(transposeSemitones, -7), 7)
    }
}
