import Foundation

/// One percussion-bank (bank 128) drum kit, with the canonical preset name and family grouping. Drives the drum-kit
/// branch of each platform's program picker for parts whose instrument reports `useDrumset == true`.
///
/// Lives in Domain rather than in the iOS Reader so Android reads the SAME catalog over JNI instead of carrying a
/// second, drifting copy of the kit list.
///
/// Programs and names match the kits actually shipped in the `jiyimeta/musescore-general-sf2-split` 1.0.0 release —
/// that resolver is the only source of percussion soundfonts, so kits outside this list would resolve to the Standard
/// fallback and silently lie to the user. When the SF2 split publishes additional kits, mirror the new `128_PPP.sf2`
/// filenames here.
public struct GMDrumKit: Equatable, Identifiable, Sendable {
    public let program: UInt8
    public let name: String
    public let family: Family
    public var id: UInt8 {
        program
    }

    public init(program: UInt8, name: String, family: Family) {
        self.program = program
        self.name = name
        self.family = family
    }

    public enum Family: String, CaseIterable, Sendable {
        case standard = "Standard"
        case room = "Room"
        case power = "Power"
        case electronic = "Electronic"
        case tr808 = "TR-808"
        case jazz = "Jazz"
        case brush = "Brush"
        case orchestra = "Orchestra"
        case marching = "Marching"

        public var kits: [GMDrumKit] {
            GMDrumKit.all.filter { $0.family == self }
        }
    }

    public static let all: [GMDrumKit] = [
        GMDrumKit(program: 0, name: "Standard", family: .standard),
        GMDrumKit(program: 1, name: "Standard 1", family: .standard),
        GMDrumKit(program: 2, name: "Standard 2", family: .standard),
        GMDrumKit(program: 3, name: "Standard 3", family: .standard),
        GMDrumKit(program: 4, name: "Standard 4", family: .standard),
        GMDrumKit(program: 5, name: "Standard 5", family: .standard),
        GMDrumKit(program: 6, name: "Standard 6", family: .standard),
        GMDrumKit(program: 7, name: "Standard 7", family: .standard),
        GMDrumKit(program: 8, name: "Room", family: .room),
        GMDrumKit(program: 9, name: "Room 1", family: .room),
        GMDrumKit(program: 10, name: "Room 2", family: .room),
        GMDrumKit(program: 11, name: "Room 3", family: .room),
        GMDrumKit(program: 12, name: "Room 4", family: .room),
        GMDrumKit(program: 13, name: "Room 5", family: .room),
        GMDrumKit(program: 14, name: "Room 6", family: .room),
        GMDrumKit(program: 15, name: "Room 7", family: .room),
        GMDrumKit(program: 16, name: "Power", family: .power),
        GMDrumKit(program: 17, name: "Power 1", family: .power),
        GMDrumKit(program: 18, name: "Power 2", family: .power),
        GMDrumKit(program: 19, name: "Power 3", family: .power),
        GMDrumKit(program: 24, name: "Electronic", family: .electronic),
        GMDrumKit(program: 25, name: "TR-808", family: .tr808),
        GMDrumKit(program: 32, name: "Jazz", family: .jazz),
        GMDrumKit(program: 33, name: "Jazz 1", family: .jazz),
        GMDrumKit(program: 34, name: "Jazz 2", family: .jazz),
        GMDrumKit(program: 35, name: "Jazz 3", family: .jazz),
        GMDrumKit(program: 36, name: "Jazz 4", family: .jazz),
        GMDrumKit(program: 40, name: "Brush", family: .brush),
        GMDrumKit(program: 41, name: "Brush 1", family: .brush),
        GMDrumKit(program: 42, name: "Brush 2", family: .brush),
        GMDrumKit(program: 48, name: "Orchestra Kit", family: .orchestra),
        GMDrumKit(program: 56, name: "Marching Snare", family: .marching),
        GMDrumKit(program: 57, name: "Old Marching Bass", family: .marching),
        GMDrumKit(program: 58, name: "Marching Cymbals", family: .marching),
        GMDrumKit(program: 59, name: "Marching Bass", family: .marching),
        GMDrumKit(program: 95, name: "Old Marching Tenor", family: .marching),
        GMDrumKit(program: 96, name: "Marching Tenor", family: .marching),
    ]

    /// Returns the catalog entry for a stored program byte, or `nil` if the program isn't a known drum kit. Callers
    /// fall back to a synthesized `"Kit \(program)"` label so an unknown override (e.g., from a future SF2 split
    /// release) still renders.
    public static func kit(for program: UInt8) -> GMDrumKit? {
        all.first { $0.program == program }
    }
}
