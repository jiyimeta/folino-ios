import SheetMusicCore

extension Score {
    /// Number of chord elements across every part / staff / measure / voice that actually sound — i.e.
    /// have at least one note. Rests (empty chords) and non-temporal elements (clefs, key signatures,
    /// dynamics, …) don't count.
    ///
    /// swift-sheet-music's PDF importer computes an analogous count independently, on the Swift side of
    /// Android's parse, as `PdfParseResultWire.playableElementCount` — Android never materializes a
    /// `Score` locally, so it crosses that raw count over the JNI boundary instead and asks
    /// `ReaderCapabilities.isPlayableElementCount(_:)` (via `nativeIsPlayableElementCount`) the same
    /// question `hasPlayableContent` asks below. Both apply the same predicate — a chord carrying at
    /// least one note — so the two counts agree exactly, not merely on zero-vs-nonzero. Keep them that
    /// way: ssm counted voice elements wholesale at first, which made a PDF whose clefs classified but
    /// whose noteheads did not report a non-zero count and enable a transport with nothing to sound.
    ///
    /// A full traversal, not an early-exit check — deliberately, since the count itself (not just
    /// whether it's nonzero) is the value that needs to cross to Android. Still a single pass with no
    /// intermediate allocations, so a several-hundred-measure score stays cheap.
    public var playableElementCount: Int {
        var count = 0
        for part in parts {
            for staff in part.staves {
                for measure in staff.measures {
                    for voice in measure.voices {
                        for element in voice.elements where element.isPlayableElement {
                            count += 1
                        }
                    }
                }
            }
        }
        return count
    }

    /// Whether this score has anything an engine could actually sound.
    ///
    /// A parse can succeed and still produce a fully-formed but silent score — e.g. the PDF OMR
    /// pipeline running over a raster "print to PDF" export that reads ruled staff lines and
    /// reconstructs parts/staves/measures, but decodes no noteheads: every voice slot ends up an
    /// empty chord (`VoiceElement.isRest`). Structural presence (parts, staves, measures) is not
    /// sufficient on its own to call a parse "playable" — see `ReaderCapabilities`'s doc, which
    /// defines the PDF playback state as unavailable when the parse "failed or yielded nothing
    /// playable." This is the "yielded nothing playable" half of that contract, decided by
    /// `ReaderCapabilities.isPlayableElementCount(_:)` so iOS (via this property) and Android (via the
    /// raw count crossing the JNI boundary) apply the identical threshold.
    public var hasPlayableContent: Bool {
        ReaderCapabilities.isPlayableElementCount(playableElementCount)
    }
}

extension VoiceElement {
    /// True when this element actually sounds: a chord with at least one note. Rests (empty
    /// chords) and non-temporal elements (clefs, key signatures, dynamics, …) don't count.
    fileprivate var isPlayableElement: Bool {
        if case let .chord(chord) = self { return !chord.notes.isEmpty }
        return false
    }
}
