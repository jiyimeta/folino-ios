import CoreGraphics
import Domain
import ReaderAnnotationCore

// PARITY(android): annotation ink vs. hidden staves — Android renders the same `filtered(hidingStaves:)` score but
//   still resolves anchors against it in display addressing, so ink drifts (and new strokes are stamped in display
//   numbering) while a staff is hidden. Kotlin holds the score, so the fix belongs where it seeds
//   `PrefetchedAnchorResolver`: translate through ssm's `filterStaffAddress` / `unfilterStaffAddress` — the same pair
//   `AnnotationStaffFilter` uses here — before/after calling the shared `AnnotationAnchoringCore`.

/// The reader's staff-visibility filter, expressed as the two `StaffAddress` translations the annotation layer needs.
///
/// **Why the annotation layer needs it at all.** Ink is anchored in SOURCE addressing — the part / staff indices of
/// the score as the file declares it, every staff present. What the containers lay out, though, is
/// `ReaderDisplayTransforms.display(…)`, whose last step is `filtered(hidingStaves:)` — and that step RENUMBERS:
/// surviving staves keep their order, a part left with no staves is dropped entirely. So a `LayoutDocument` built
/// while anything is hidden speaks a different addressing than the stored anchors, in both directions:
///
/// * **Display.** A stroke anchored to source staff 2 resolves against whatever staff sits at index 2 in the filtered
///   document — a different instrument — and draws there. A stroke on a HIDDEN staff resolves against nothing it
///   should, and used to keep drawing at a stale position.
/// * **Capture.** `LayoutDocument.resolveAnchor(at:)` answers in the document's own (filtered) addressing. Stamped
///   into a `MusicalAnchor` and saved, that is a display-space number in a source-space field — the layer is then
///   permanently wrong, and un-hiding the staff cannot recover it. This is the corrupting half; it is closed by
///   translating every captured anchor back to source addressing before it reaches the model.
///
/// This is display-only. Nothing here touches the stored layer: hiding a staff hides its ink, showing it brings the
/// ink back, and the bytes never move.
///
/// The translation itself is ssm's own `filterStaffAddress` / `unfilterStaffAddress` — the same pair
/// `ReaderEditingHost` re-stamps editor IDs with and the playback cursor rides through this exact mismatch. It is
/// deliberately not re-derived here.
struct AnnotationStaffFilter {
    /// The score in SOURCE addressing: every staff the file declares, hidden ones included. The renumbering is a
    /// function of this score's part / staff shape, so it has to be the unfiltered one.
    let sourceScore: Score
    /// What the reader is currently hiding, in source addressing.
    let hiddenStaves: Set<StaffAddress>

    /// Source (full-score) staff → its position in the rendered, staff-filtered document. `nil` when the staff is
    /// itself hidden (or its enclosing part is fully hidden) — there is nothing on screen to draw against.
    func displayAddress(for source: StaffAddress) -> StaffAddress? {
        sourceScore.filterStaffAddress(source, hidingStaves: hiddenStaves)
    }

    /// Rendered-document staff → source addressing, which is what the stored anchors are in. `nil` when the address
    /// can't be placed back in the full score.
    func sourceAddress(for display: StaffAddress) -> StaffAddress? {
        sourceScore.unfilterStaffAddress(display, hidingStaves: hiddenStaves)
    }

    /// The musical anchors this filter is currently hiding — the ones no canvas can show and therefore no capture can
    /// describe.
    ///
    /// **They have to be carried across a capture by hand.** The vertical and horizontal containers commit ink by
    /// REPLACING the whole score layer with what the canvas holds (`AnnotationLayers.replacing(.score, …)`), which is
    /// correct only while everything the layer contains is on screen. Hide a staff and its strokes are no longer on
    /// the canvas — so a replacement would delete them permanently, on a display-only setting the user expects to be
    /// able to undo by showing the staff again. The paged container gets this for free: a hidden staff's anchor does
    /// not resolve, so `partitionByPage` already files it under `offPage`, which that path preserves verbatim.
    ///
    /// Only anchors hidden BY THIS FILTER are returned, and the test is membership in `hiddenStaves` — deliberately
    /// NOT "`displayAddress` came back nil". That weaker test also catches an anchor naming a staff the score does not
    /// have at all (a part removed since the ink was drawn), which is exactly the case the existing
    /// prune-on-next-capture behavior is meant to clear: carrying it would keep resurrecting ink for a staff that no
    /// longer exists, forever, since nothing else ever drops it. The staff has to exist AND be hidden.
    func hiddenAnchors(in drawings: [DrawingAnchor]) -> [DrawingAnchor] {
        drawings.filter { drawing in
            guard case let .musical(anchor) = drawing.kind else { return false }
            let address = anchor.staffAddress
            guard hiddenStaves.contains(address), sourceScore.parts.indices.contains(address.partIndex) else {
                return false
            }
            return sourceScore.parts[address.partIndex].staves.indices.contains(address.staffIndexInPart)
        }
    }
}

extension AnnotationStaffFilter {
    /// The filter for what the reader is showing right now, or `nil` when there is nothing to translate — no staff
    /// hidden (the overwhelmingly common case, where the rendered document already speaks source addressing) or no
    /// score loaded yet.
    ///
    /// The source score is picked exactly the way `ReaderRootScreen` wires `ReaderEditingHost.sourceScoreProvider`:
    /// the editor's live score while a session is up (a part it just added is not in the loaded copy yet), the
    /// loaded score otherwise. Spelled once, here, so the ink and the editor's hit tests cannot disagree about which
    /// score the renumbering was computed from.
    @MainActor
    static func current(viewModel: ReaderViewModel, editingHost: ReaderEditingHost?) -> AnnotationStaffFilter? {
        let hidden = viewModel.layoutModel.hiddenStaves
        guard !hidden.isEmpty else { return nil }
        guard let score = editingHost?.editedScore ?? viewModel.loadState.score else { return nil }
        return AnnotationStaffFilter(sourceScore: score, hiddenStaves: hidden)
    }
}

/// An `AnchorResolving` that makes a resolver built on a staff-FILTERED layout speak SOURCE addressing on both sides.
///
/// One decorator rather than a translation at each call site: `AnnotationAnchoringCore`'s entry points
/// (`capture` / `display` / `partitionByPage` / `anchorPoint`) all reach the layout through this protocol, so wrapping
/// it fixes every one of them at once and keeps the shared core free of any notion of hidden staves.
///
/// `nil` from either translation propagates as "this anchor does not resolve in the current layout" — precisely the
/// contract the core already has for an out-of-range measure. Display skips it, `partitionByPage` files it under
/// `offPage` (preserved, never dropped), and capture drops the stroke.
struct FilteredStaffAnchorResolver: AnchorResolving {
    let base: AnchorResolving
    let filter: AnnotationStaffFilter

    /// Document point → anchor. The base answers in DISPLAY addressing; translate to source before it escapes.
    func resolveAnchor(at point: CGPoint) -> MusicalAnchor? {
        guard let displayed = base.resolveAnchor(at: point),
              let source = filter.sourceAddress(for: displayed.staffAddress)
        else { return nil }
        return displayed.onStaff(source)
    }

    /// Anchor → document point. The anchor is in SOURCE addressing; translate to display before the base looks it up.
    func referencePoint(for anchor: MusicalAnchor) -> (point: CGPoint, sp: CGFloat)? {
        guard let display = filter.displayAddress(for: anchor.staffAddress) else { return nil }
        return base.referencePoint(for: anchor.onStaff(display))
    }
}

extension MusicalAnchor {
    /// The anchor's staff identity, which `MusicalAnchor` carries as two loose `Int`s.
    var staffAddress: StaffAddress {
        StaffAddress(partIndex: partIndex, staffIndexInPart: staffIndexInPart)
    }

    /// The same anchor on a different staff — musical position (measure, tick) and sp offsets untouched, exactly as
    /// `ReaderEditingHost.restamping` moves an item's ID without touching its measure / voice / element indices.
    func onStaff(_ address: StaffAddress) -> MusicalAnchor {
        MusicalAnchor(
            measureIndex: measureIndex,
            tickInMeasure: tickInMeasure,
            partIndex: address.partIndex,
            staffIndexInPart: address.staffIndexInPart,
            dxSp: dxSp,
            verticalOffsetSp: verticalOffsetSp,
        )
    }
}
