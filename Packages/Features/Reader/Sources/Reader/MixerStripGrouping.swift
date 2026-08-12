import Domain

/// How the playback mixer turns the engine's flat strip list into rows. Lives outside `PlaybackInspectorScreen` so the
/// screen file stays under its length budget, and so the shape decisions — pure logic over `[MixerStrip]` — can be
/// unit-tested without standing up a view.
extension [MixerStrip] {
    /// The strips of one part, in the engine's order.
    struct PartGroup: Identifiable {
        let partIndex: Int
        let partName: String
        fileprivate(set) var strips: [MixerStrip]
        var id: Int {
            partIndex
        }

        /// Whether the group draws a part header above its rows. One strip over one staff does not: it collapses to a
        /// single row, the shape the mixer has always had, and most scores are entirely that case. Anything else needs
        /// the header — which is also the only thing left corresponding to a SET of staves, so it carries their eyes.
        func drawsHeader(staffCount: Int) -> Bool {
            !(strips.count == 1 && staffCount == 1)
        }

        /// A strip's row label under that header, or `nil` when the part has a single strip: the header already named
        /// it, and for a grand staff the two strings would be the same word.
        func rowLabel(for strip: MixerStrip) -> String? {
            strips.count == 1 ? nil : strip.instrumentName
        }
    }

    /// Strips bucketed by part, keeping the engine's order — by part, then by ordinal — rather than sorting. Sorting
    /// would reorder the mixer against the score the user is looking at.
    func grouped() -> [PartGroup] {
        var groups: [PartGroup] = []
        var positionOfPart: [Int: Int] = [:]
        for strip in self {
            if let position = positionOfPart[strip.id.partIndex] {
                groups[position].strips.append(strip)
            } else {
                positionOfPart[strip.id.partIndex] = groups.count
                groups.append(
                    PartGroup(partIndex: strip.id.partIndex, partName: strip.partName, strips: [strip]),
                )
            }
        }
        return groups
    }
}
