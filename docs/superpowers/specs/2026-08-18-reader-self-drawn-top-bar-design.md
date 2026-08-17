# The Reader's top bar, drawn by us again — design

2026-08-18. Takes the Reader's top chrome — and the editing chrome that shares
it — out of the system navigation bar and back into a view we draw, so that a
control can say where it is and the bar can occupy the status bar's space while
editing.

## The problem

Two things the standard toolbar cannot do, both of which now cost more than the
toolbar earns.

**A bar item cannot report its position.** Measured on iOS 26 and written down
in `Reader/Hints/ReaderBarItemLocator.swift`: `frame(in: .global)` inside a
`ToolbarItem` returns the item's own bounds centred on the origin, a
`UIViewRepresentable` planted in an item never reaches a window,
`accessibilityIdentifier` is not burned into any view under the bar, and
`UINavigationBar.topItem.rightBarButtonItems` is empty because SwiftUI drives
the bar through its own plumbing. The coach marks therefore walk the rendered
UIKit hierarchy, cluster overlapping subviews into controls, and match them to
hints **by counting in from each end of the bar** — a hint declares an ordinal,
not a target. When the count disagrees with what was measured the bubble is
suppressed rather than risk pointing at the wrong button.

**A `ToolbarContent` cannot measure itself.** So the fold that keeps the row
inside the bar's width budget is arithmetic instead of layout:
`ReaderToolbarCollapse.Metrics` carries an `item: 55` derived from bracketing
observations on real devices (402pt overflowed six buttons; 393pt must still fit
five), and it must be re-derived by hand whenever a button is added.

On top of both, the bar cannot be moved into the status bar's space, which is
where Photos puts Revert while editing — the shape this feature was reaching for.

## Scope

The Reader's own top chrome **and** the editing chrome that replaces it, both
drawn by us. The status bar is hidden while editing and shown otherwise.

Out of scope: the transport, the note pad, the callout, and every inspector.
They are already views we draw and are untouched.

## Prior art, and the one thing not to copy

The Reader drew this chrome itself until `f3cdbd94` (2026-08-02) moved it into a
standard toolbar. The old implementation is
`Packages/Features/Reader/Sources/Reader/Screens/ReaderTopOverlay.swift` at
`f3cdbd94^` (381 lines).

**Reuse from it, without redesigning:** the `ViewThatFits` ladder that folds the
row, the glass treatment (`UtilityUI/GlassEffectCompat`,
`floatingToolbarBackgroundCompat()`), and the self-drawn leading affordance for
the iPad split-view detail.

**Do not copy its height handling.** It subtracted a fixed `52pt` from the safe
area, and every call site doing that broke when the standard bar arrived —
`f3cdbd94`'s own message records removing it. This design replaces that constant
with a contract (below); reinstating the constant reinstates the bug.

**It answers nothing about four things**, because none of them existed yet: the
coach marks and their anchoring (`619e3b53`, `ReaderBarItemLocator` 2026-08-05),
the editing chrome sharing this strip (`9cdd52cb`), a self-drawn back button on
compact — `f3cdbd94` states the compact stack *gained* the system back button in
that commit, so the overlay era never had one — and hiding the status bar. Those
four are what the rest of this document is about.

## The strip

`ReaderTopBar` is one view, attached to the Reader's root with
`safeAreaInset(edge: .top)`. The Reader draws its own controls into it; while an
edit session runs it draws the App-injected editing row into the same strip
instead. The system navigation bar is hidden for the duration
(`toolbarVisibility(.hidden, for: .navigationBar)`), which also removes iOS 26's
own overflow menu — the mechanism whose contents and priority we cannot
influence, and which reliably swallowed the inspectors first.

**The height contract, which is the reason this design is shaped this way:**
the strip always occupies *status-bar height + control-row height*. While
editing, the status bar is hidden and the control row grows by exactly the
status-bar height. The total top inset is therefore identical in both states, so
**entering or leaving an edit session cannot move a paged score's page breaks**.

The hide applies in both size classes, so there is one height rule rather than
two. Reclaiming the strip matters less on an iPad than on a phone, and if it
reads wrong there the hide can be made compact-only without touching anything
else — the contract is stated in terms of the total, which holds either way.

That invariant is why the strip is owned by one view rather than negotiated
between two. Today the Reader keeps its navigation bar mounted-but-empty during
editing for the same reason, achieving it by accident of the bar's presence; here
it is stated, computed in one place, and testable.

**The fold** returns to `ViewThatFits` over a list of candidate rows written in
priority order — the same ladder the old overlay used, and the same priority the
current `Collapse` enum declares (score info and share first, then note editing,
then annotation; the inspectors never fold). `ReaderToolbarCollapse` and its
`Metrics` are deleted: the derived `item: 55`, the device observations that
bracket it, the `hasLeadingAffordance` branch, and the breakpoint tests.

**Appearance** is ours directly, so `toolbarColorScheme(.light, for:
.navigationBar)` goes away with the bar it configured.

## Leading affordances

**Compact (`NavigationStack` push).** A chevron we draw, calling `dismiss()`.
Edge-swipe back is restored by a small `UIViewControllerRepresentable` in
`UtilityUI` that finds the enclosing `UINavigationController` and installs a
delegate on its `interactivePopGestureRecognizer` — no private API. Long-press
back for a hierarchy jump is **not** restored; this screen is one level deep.

**Regular (`NavigationSplitView` detail).** A sidebar toggle we draw, shown
whenever the layout is regular, flipping `columnVisibility` **in both
directions**. The old overlay showed its toggle only in `.detailOnly`, which is
why removing the system one once left no way to collapse an open sidebar.
`columnVisibility` belongs to `AppShellView`, so the Reader takes an
`onToggleSidebar` closure.

No navigation title is shown, matching what `.toolbarRole(.editor)` effectively
gives today.

## Coach-mark anchoring: ordinals become frames

Every control in the strip is now in the Reader's own view tree, so all of them
report a window frame through the existing
`UtilityUI/WindowFrameReader.onWindowFrameChange` — the helper the transport's
anchors already use, and which already pairs a SwiftUI geometry callback with
`layoutSubviews` because the latter alone misses a purely horizontal shift.

**Deleted:** `ReaderBarItemLocator` entirely; `ReaderBarSlot`;
`ReaderHintTarget.barSlot`; `ReaderHintCoordinator`'s `barTargets`,
`registerBarTarget`, `refreshBarAnchors`, `assign`, `setReaderRegion`, and the
0/120/320/700/1400 ms resampling; `readerHintBarAnchor` (folded into
`readerHintAnchor`); and the tests pinning the clustering threshold against iOS
18 and iOS 26 measured frames.

**The seam changes shape.** The Editor's pad toggle lives in App-injected code,
so it still reports through `ReaderEditingHost` — but as
`noteInputAnchorFrame: CGRect?` rather than `noteInputBarLeadingOrder: Int?`.
The injected chrome is rendered inside the Reader's tree, so the two share a
window coordinate space. (`ReaderHintTarget.noteInputToggle`'s doc comment
already names `noteInputAnchorFrame`; the implementation catches up to it.)

**Two compromises disappear.** Suppressing a bubble when the ordinal count
disagrees is no longer needed — a control that is not rendered reports no frame,
lands in no anchor, and is skipped. For the same reason the hints stop consulting
the fold level to decide eligibility.

## The editing strip

Leading: the voice picker and the pad toggle. Trailing: revert, undo, redo, 完了.

**The `⋯` overflow menu is removed.** It holds exactly one item — revert — and
exists only because a sixth item risked the standard bar folding undo, redo and
完了 into a system menu of its own choosing. `ViewThatFits` removes that risk, so
revert becomes a top-level control, which is also the shape this feature was
after: visible at the top of the editing screen, the way Photos shows Revert.
The confirmation dialog in front of it is unchanged.

## Testing

- **The height contract.** A unit test asserting the strip's total top inset is
  equal in the editing and non-editing states, across the status-bar heights of
  a notch device, a Dynamic Island device, and one without either. This does not
  exist today and is the invariant the whole design turns on.
- **The fold.** Which candidate row `ViewThatFits` selects at representative
  widths, replacing the deleted breakpoint tests.
- Deleted: the `Metrics` breakpoint tests and the `ReaderBarItemLocator`
  clustering tests.
- Anchoring is wired, not computed, so the tests cover that a control's frame
  reaches the coordinator; the coordinates themselves belong to the device
  checklist.

## Risks

- **Edge-swipe restoration is a UIKit touch point.** It replaces a larger one,
  and it uses no private API, but it is a place a future iOS can change under
  us. It is isolated in `UtilityUI` so a failure is one file.
- **The strip's height must track the status bar across rotation and Dynamic
  Island states.** The contract makes this checkable; the test above is what
  keeps it honest.
- **Accessibility and Liquid Glass are ours now.** The old overlay's treatment is
  the starting point, but VoiceOver ordering and the glass behind the row are no
  longer supplied.

## Implementation order

1. `ReaderTopBar` with the height contract and the `ViewThatFits` fold, drawing
   the Reader's own controls; navigation bar hidden; `ReaderToolbar` and
   `ReaderToolbarCollapse` deleted.
2. Leading affordances: chevron plus edge-swipe restoration, and the
   bidirectional iPad sidebar toggle.
3. Anchoring: frames replace ordinals; `ReaderBarItemLocator` and its
   surrounding machinery deleted; the seam becomes `noteInputAnchorFrame`.
4. The editing strip: status-bar absorption, revert promoted out of `⋯`.
