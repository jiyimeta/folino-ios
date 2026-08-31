import Foundation
import SheetMusicCore

/// One key of the drum pad: which instrument it writes, how that instrument is engraved, and which hand plays it.
///
/// An instrument and its voice are 1:1 on a drum staff — a bass drum is always the feet voice — which is what lets
/// the voice ride on the key. A pitched C–B key cannot carry one (pressing "C" does not say which voice it belongs
/// to), and that difference is the whole reason one caret model serves both (drum note entry's §2).
public struct DrumPadKey: Sendable, Equatable, Codable, Identifiable {
    /// MIDI drum pitch, 35…81. Also the identity: a layout never holds the same instrument twice.
    public var pitch: Int
    /// The GM name, in English. NOT what the key face shows — a host localizes the label from `pitch`, because
    /// `String(localized:)` needs a bundle and this type has to cross into an Android `.so`.
    public var name: String
    /// The notehead written with the note (`cross`, `slashed1`, `normal`, …), and drawn on the key face.
    public var headType: String?
    /// The staff line, for the key's own preview glyph.
    public var line: Int
    /// Which voice this instrument is written into.
    public var voiceIndex: Int

    public var id: Int {
        pitch
    }

    public init(pitch: Int, name: String, headType: String?, line: Int, voiceIndex: Int) {
        self.pitch = pitch
        self.name = name
        self.headType = headType
        self.line = line
        self.voiceIndex = voiceIndex
    }

    /// Every drum GM names, ascending — the instrument list a layout editor offers. Exposed here so a host does
    /// not have to reach past this module into `SheetMusicCore` for the table.
    public static let allGMPitches: [Int] = GMDrumset.entries.keys.sorted()

    /// The key GM would make for `pitch`, or `nil` for a pitch the table does not name.
    public init?(gmPitch pitch: Int, voiceIndex: Int? = nil) {
        guard let entry = GMDrumset.entries[pitch] else { return nil }
        self.init(
            pitch: pitch,
            name: entry.name,
            headType: entry.head,
            line: entry.line,
            voiceIndex: voiceIndex ?? entry.voiceIndex,
        )
    }
}

/// The keys the pad shows, in order, and how many rows to spread them over.
///
/// **Global, not per-score.** The user asked for a fixed core they can learn, and a layout that reshuffles itself
/// per file defeats that. What IS per-score is the engraving each key describes — `resolved(against:)` — and the
/// voice preset, which is pre-selected from what the open file actually does.
public struct DrumPadLayout: Sendable, Equatable, Codable {
    /// The keys, already split into the rows the pad draws them on.
    ///
    /// Rows are stored rather than derived from a count because they no longer have to be the same length: the
    /// layout editor adds and removes instruments a row at a time, and an iPad has room for a row a phone does not.
    /// Nothing caps how many keys a row may hold — a row too crowded to read is one the user can thin out
    /// themselves, and guessing a limit for every screen size would be worse.
    public var rows: [[DrumPadKey]]

    /// Every key, in pad order — the flat view the pad's lit state and the ⋯ menu work in.
    public var keys: [DrumPadKey] {
        rows.flatMap(\.self)
    }

    /// Row 1 of the pad is always the durations, so this counts the INSTRUMENT rows below it.
    public var rowCount: Int {
        rows.count
    }

    /// How many instrument rows the pad will draw. The card has to stay a card; past this it stops being a pad and
    /// starts being a keyboard.
    public static let maxRowCount = 3

    public init(rows: [[DrumPadKey]]) {
        self.rows = rows.isEmpty ? [[]] : rows
    }

    /// One flat list spread over `rowCount` rows, the earlier rows taking the extra key when the split is uneven.
    /// Kept for the stored layouts written before rows were explicit, and for callers that only have a list.
    public init(keys: [DrumPadKey], rowCount: Int) {
        let count = min(max(rowCount, 1), Self.maxRowCount)
        guard count > 1, !keys.isEmpty else {
            self.init(rows: [keys])
            return
        }
        let perRow = Int(ceil(Double(keys.count) / Double(count)))
        self.init(rows: stride(from: 0, to: keys.count, by: perRow).map {
            Array(keys[$0 ..< min($0 + perRow, keys.count)])
        })
    }

    // MARK: - Codable

    /// Written as `rows`; read as either. A layout stored by an earlier build is a flat `keys` list plus a count,
    /// and silently falling back to the default kit would throw away a pad the user had arranged by hand.
    private enum CodingKeys: String, CodingKey {
        case rows, keys, rowCount
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let rows = try container.decodeIfPresent([[DrumPadKey]].self, forKey: .rows) {
            self.init(rows: rows)
        } else {
            try self.init(
                keys: container.decode([DrumPadKey].self, forKey: .keys),
                rowCount: container.decodeIfPresent(Int.self, forKey: .rowCount) ?? 1,
            )
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(rows, forKey: .rows)
    }

    /// Fourteen instruments over two rows, laid out the way the kit is: cymbals above, drums below, each row
    /// running left to right across the player's setup.
    ///
    /// Seven and seven, because the pad's two rows each close with a key of their own — the rest above, the menu of
    /// drums the pad does not show below — so an even split is what makes both rows the same width.
    ///
    /// Four toms, not GM's six. A kit with six toms is rare, and the two that go (hi-mid 48 and low floor 41) are
    /// the two a chart is least likely to use; a file that does use them still plays and still engraves, it just
    /// reaches them through the menu instead of a key. Both crashes are here because the pair is what the tilt in
    /// their icons is for.
    ///
    /// Every pitch is one `GMDrumset` names, so no key can render as an unnamed drum, and the voices are GM's own
    /// split — which is `DrumVoicePreset.handsAndFeet`, the preset most drum charts imply.
    public static let `default` = DrumPadLayout(rows: [
        [42, 46, 44, 49, 57, 51, 56].compactMap { DrumPadKey(gmPitch: $0) },
        [38, 37, 50, 47, 45, 43, 36].compactMap { DrumPadKey(gmPitch: $0) },
    ])

    /// This layout with each key's engraving taken from `instrument`'s own kit where it defines one.
    ///
    /// An imported chart that puts the ride on a non-standard line must keep that line: the pad is for correcting
    /// the file in front of you, and a key drawn where the file does not put it would misdescribe what pressing it
    /// does. Pitches the file says nothing about keep the GM answer — including the voice, which is the layout's
    /// own and never the file's.
    public func resolved(against instrument: Instrument) -> DrumPadLayout {
        DrumPadLayout(rows: rows.map { row in
            row.map { key in
                guard let entry = instrument.drumset[key.pitch] else { return key }
                var resolved = key
                resolved.name = entry.name
                resolved.headType = entry.head
                resolved.line = entry.line
                return resolved
            }
        })
    }
}

/// Which hand plays what — the one-tap answer, editable per key afterwards.
public enum DrumVoicePreset: String, Sendable, CaseIterable, Codable {
    /// Every key in voice 1. What a chart written on one voice wants.
    case singleVoice
    /// The bass drums and the pedal hi-hat in voice 2, everything else in voice 1 — MuseScore's own split, and
    /// the convention a drum part is normally engraved with. The low floor tom stays in the hands, where it is
    /// played from.
    case handsAndFeet

    public func applied(to layout: DrumPadLayout) -> DrumPadLayout {
        DrumPadLayout(rows: layout.rows.map { row in
            row.map { key in
                var applied = key
                applied.voiceIndex = switch self {
                case .singleVoice: 0
                case .handsAndFeet: GMDrumset.entries[key.pitch]?.voiceIndex ?? 0
                }
                return applied
            }
        })
    }

    /// The preset `staff` is already written in: hands-and-feet the moment ANY of its bars uses a second voice,
    /// single-voice otherwise.
    ///
    /// Asked when a session opens on a drum staff, so the pad starts out agreeing with the file rather than making
    /// the user restate what the file already says.
    public static func implied(by score: Score, staff: StaffAddress) -> DrumVoicePreset {
        guard score.parts.indices.contains(staff.partIndex),
              score.parts[staff.partIndex].staves.indices.contains(staff.staffIndexInPart)
        else { return .singleVoice }
        let measures = score.parts[staff.partIndex].staves[staff.staffIndexInPart].measures
        return measures.contains { $0.voices.count > 1 } ? .handsAndFeet : .singleVoice
    }
}
