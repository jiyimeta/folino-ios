import Foundation
import SheetMusicCore

/// Migrating per-score preferences through a change to the score's PARTS.
///
/// Everything a reader sets per staff or per mixer strip is addressed by part INDEX — hidden staves, clef overrides,
/// the strip program / volume overlays. Adding, removing or reordering a part renumbers those indices in the file
/// while the stored row keeps pointing at the old numbers, so without this rewrite hiding a piano's lower staff and
/// then deleting the part above it makes the piano's staff reappear and hides some other part's staff instead — and
/// the wrong state is what gets persisted.
///
/// The mapping comes from `ScoreEditSession.partIndexMapping`, which is cumulative since the last consume point and
/// derived by diffing `Part.id`s, so undo and redo need no special handling.
extension ReaderPreferences {
    /// Rewrites every part-indexed key for a part add / remove / reorder. `mapping` covers every pre-edit part index;
    /// `nil` = the part was removed (its rows are dropped). Staff indices within a part — and instrument ordinals
    /// within a strip — are unchanged by part operations, so `staffIndexInPart` / `instrumentOrdinal` are preserved.
    ///
    /// A key whose `partIndex` the mapping does not mention at all is DROPPED rather than passed through. Such a row
    /// is either corrupt or addresses a part appended after the mapping's baseline was taken, and in both cases the
    /// old index is not a claim about the new numbering: passing it through would silently re-point the setting at
    /// whatever part now sits there. Losing a setting is recoverable; pointing it at the wrong instrument is not.
    ///
    /// The result is built through the memberwise `init`, so the initializer's clamping and filtering re-apply to the
    /// migrated row exactly as they would to a fresh one.
    public func remappingParts(_ mapping: [Int: Int?]) -> ReaderPreferences {
        func destination(of partIndex: Int) -> Int? {
            // Double Optional: the outer level is "the mapping knows this index", the inner "the part survived".
            guard let mapped = mapping[partIndex] else { return nil }
            return mapped
        }
        func remap(_ address: StaffAddress) -> StaffAddress? {
            guard let partIndex = destination(of: address.partIndex) else { return nil }
            return StaffAddress(partIndex: partIndex, staffIndexInPart: address.staffIndexInPart)
        }
        func remap(_ strip: MixerStripID) -> MixerStripID? {
            guard let partIndex = destination(of: strip.partIndex) else { return nil }
            return MixerStripID(partIndex: partIndex, instrumentOrdinal: strip.instrumentOrdinal)
        }
        func remapKeys<Key: Hashable, Value>(
            _ source: [Key: Value], _ transform: (Key) -> Key?,
        ) -> [Key: Value] {
            // `uniquingKeysWith` can never actually fire: the mapping is injective over the indices it maps (it is a
            // position lookup of distinct part ids), so two distinct keys cannot collide on one destination. Keeping
            // the FIRST is the arbitrary-but-defined answer if a malformed mapping ever made it non-injective.
            Dictionary(
                source.compactMap { key, value in transform(key).map { ($0, value) } },
                uniquingKeysWith: { first, _ in first },
            )
        }
        return ReaderPreferences(
            id: id,
            scoreItemID: scoreItemID,
            staffSize: staffSize,
            hiddenStaves: Set(hiddenStaves.compactMap(remap)),
            authoredHiddenStaves: Set(authoredHiddenStaves.compactMap(remap)),
            stripProgramOverrides: remapKeys(stripProgramOverrides, remap),
            stripVolumeOverrides: remapKeys(stripVolumeOverrides, remap),
            staffClefOverrides: remapKeys(staffClefOverrides, remap),
            tempoMultiplier: tempoMultiplier,
            honorLayoutBreaks: honorLayoutBreaks,
            repeatMode: repeatMode,
            abRepeat: abRepeat,
            masterVolume: masterVolume,
            transposeSemitones: transposeSemitones,
            a4ReferenceHz: a4ReferenceHz,
            hasSeededAuthoredVisibility: hasSeededAuthoredVisibility,
        )
    }
}
