# The Reader's top bar, drawn by us again — design

2026-08-18. Takes the Reader's top chrome — and the editing chrome that shares
it — out of the system navigation bar and back into a view we draw, so that a
control can say where it is and the bar can reach into the band the display
cutout already reserves.

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

On top of both, the bar cannot be drawn into the top safe area, which is where
Photos puts Revert while editing — the shape this feature was reaching for.

That third point needs stating precisely, because the obvious reading of it is
wrong. **Hiding the status bar does not shrink the top safe-area inset on a
notched or Dynamic Island device.** The inset belongs to the cutout, and the
system keeps reserving it. Photos gains no height by hiding the status bar. What
it gains is a *place*: the cutout is centred, so the band's leading and trailing
ends are free, and Photos draws its close button and its Revert pill there,
flanking the island, with a second row of controls below. Hiding the status bar
is what stops the clock and the battery from sitting in exactly those two spots.

So the prize is not a larger score. It is **two rows of controls for the price of
one row of inset** — the upper row is free, because it occupies space the system
reserves whether we use it or not.

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

The strip has **two tiers**, and only one of them costs anything.

**The cutout tier** is drawn inside the top safe area, flanking the cutout, and
adds nothing to the score's inset — the system reserves that band regardless. It
exists only on devices whose top safe-area inset is at least 44pt, which is a
tappable control's height: notched and Dynamic Island iPhones in portrait. An SE,
an iPad, and any phone in landscape report 20-24pt or nothing, so there is no
room for a control and **no cutout tier is drawn there**. That branch is
deliberate and is the price of the Photos shape.

**The control tier** sits below the safe area and is the only thing that adds
inset. Its height does not depend on the device, on the cutout tier's presence,
or on whether an edit session is running.

**The height contract, which is the reason this design is shaped this way:** the
inset the strip contributes is the control tier's height and nothing else — a
constant. So **entering or leaving an edit session cannot move a paged score's
page breaks**, and neither can a device having a cutout.

Stating it this way is what makes it hold. The first draft of this design had the
control tier *absorb* the status bar's height while editing, on the premise that
hiding the status bar reclaimed it. It does not, on exactly the devices the
feature was aimed at; the contract would have been an identity that only held on
an SE. Nothing is absorbed here — the two tiers are independent, and the one that
varies by device is the one that costs nothing.

That invariant is why the strip is owned by one view rather than negotiated
between two. Today the Reader keeps its navigation bar mounted-but-empty during
editing for the same reason, achieving it by accident of the bar's presence; here
it is stated, computed in one place, and testable.

**The status bar is hidden while the cutout tier is in use** — that is, while
editing on a device that has one — because the clock and the battery occupy the
two spots the tier wants. It is shown otherwise. Hiding it changes no height.

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

**Cutout tier**, where there is one: 完了 at the leading end, revert at the
trailing end — the two the user reaches for to end the session, in the two spots
Photos uses for the same purpose.

**Control tier**: the voice picker and the pad toggle leading, undo and redo
trailing. On a device with no cutout tier, 完了 and revert join this row, which
is then five controls wide and folds like any other.

**The `⋯` overflow menu is removed.** It holds exactly one item — revert — and
exists only because a sixth item risked the standard bar folding undo, redo and
完了 into a system menu of its own choosing. `ViewThatFits` removes that risk, so
revert becomes a top-level control, which is also the shape this feature was
after: visible at the top of the editing screen, the way Photos shows Revert.
The confirmation dialog in front of it is unchanged.

*(As shipped, the fold has its own `⋯` overflow — see "The editing row folds
too" below — which is a different mechanism from the one this paragraph
removes: this one is a `ViewThatFits` candidate that only appears on a device
with no cutout tier that has also run out of width, not the standard bar's
own overflow menu of undo/redo/完了/revert.)*

**The editing row folds too.** It has the same `ViewThatFits` ladder as the
Reader's own row — on a narrow width (an iPad Slide Over, a 320pt column) the
device without a cutout tier is carrying five controls, and nothing about being
the editing row exempts it from running out of room.

**As shipped (added after Task 5's review round): the fold is two rungs, not
three.** `ViewThatFits` can only select a candidate that is measurably narrower
than the one above it. A middle rung — revert first, then 完了, as this
paragraph's "the same ladder" comparison to the Reader's graduated fold might
suggest — swapped one fixed 44×44 icon (revert) for another (完了 as an
overflow trigger) and so measured identical to the row above it whenever
revert was showing, and identical again when it wasn't: a candidate
`ViewThatFits` can never select is not a fold level, it is dead code that reads
as safety. The shipped ladder is `.expanded` → `.folded`, where `.folded`
collapses revert and 完了 into the `⋯` overflow menu together in one step, with
`doneButton` pinned to `.frame(minWidth: 60)` so `.folded` is measurably
narrower than `.expanded` by construction — in every locale and every
`canRevertToOriginal` state, not only the ones where a particular localized
label happens to be short.

**Also as shipped: the confirmation dialog's anchor moved off the revert
button.** It attaches to the editing strip's own stable root, not to the
revert control itself, deliberately: a button inside a `ViewThatFits` ladder is
exactly the kind of anchor a refold can tear an open presentation out from
under, and this codebase has shipped that failure mode before. The trade is
that on iPad the dialog's popover arrow indicates the strip rather than the
revert icon specifically.

## Testing

- **The height contract.** A unit test asserting the inset the strip contributes
  is the control tier's height alone — equal whether or not an edit session is
  running, and equal across every top safe-area inset that ships (0 in landscape,
  20 on an SE, 24 on an iPad, 44-59 for cutouts). This does not exist today and
  is the invariant the whole design turns on. It must be a test of what is
  *contributed*, not of a total that includes the system's own inset; the first
  draft asserted the latter and would have passed while the real inset moved.
- **The cutout-tier rule.** Which safe-area insets get a cutout tier, at the 44pt
  boundary and either side of it.
- **The fold.** Which candidate row `ViewThatFits` selects at representative
  widths, replacing the deleted breakpoint tests.
- Deleted: the `Metrics` breakpoint tests and the `ReaderBarItemLocator`
  clustering tests.
- **As shipped: the fold has no automated replacement.** `ViewThatFits`
  resolves candidates through SwiftUI's own layout pass, which is not
  something a unit test can drive the way the deleted arithmetic tests drove
  `Metrics`, and no Xcode MCP tooling was available during this plan's
  execution to render and measure a preview at representative widths either.
  The bullet above was the intent; the "no automated means exists here" gap
  is recorded in the plan's per-task notes rather than closed. The fold is
  verified by the device checklist instead (Task 6), which names the widths
  and the expected give-way order and states plainly what a failed fold looks
  like: nothing, until a narrow device overflows its row.
- Anchoring is wired, not computed, so the tests cover that a control's frame
  reaches the coordinator; the coordinates themselves belong to the device
  checklist.

## Risks

- **Edge-swipe restoration is a UIKit touch point.** It replaces a larger one,
  and it uses no private API, but it is a place a future iOS can change under
  us. It is isolated in `UtilityUI` so a failure is one file.
- **The layout branches on device category.** A cutout tier exists on some
  devices and not others, and rotating a phone removes it mid-session. The
  contract confines the damage — the contributed inset does not change either way
  — but the two-tier and one-tier arrangements are genuinely different screens
  and both need looking at.
- **The cutout's width is not ours to know.** The tier's two clusters flank a
  centred cutout whose width varies by model. Anything placed there must be
  small, pinned to its own edge, and must not assume how much room the middle
  has.
- **Accessibility and Liquid Glass are ours now.** The old overlay's treatment is
  the starting point, but VoiceOver ordering and the glass behind the row are no
  longer supplied.

## Implementation order

1. `ReaderTopBar` with the height contract and the `ViewThatFits` fold, drawing
   the Reader's own controls; navigation bar hidden; `ReaderToolbar`,
   `ReaderToolbar+PDF` and `ReaderToolbarCollapse` deleted.
2. Leading affordances: chevron plus edge-swipe restoration, and the
   bidirectional iPad sidebar toggle.
3. Anchoring: frames replace ordinals; `ReaderBarItemLocator` and its
   surrounding machinery deleted; the seam becomes `noteInputAnchorFrame`.
4. The editing strip: the cutout tier, revert promoted out of `⋯`, the status bar
   hidden while the tier is in use.
