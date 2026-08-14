# Android note editing SP4 — Compose UI

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or
> superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Put the note-editing session SP3 proved on screen — a contextual app bar, a bottom pad, a callout beside
the selected note, a caret overlay and a tinted selection — so a user can write notes into a score on Android.

**Architecture:** SP3 landed everything below the UI: `EditSessionRelay` is the single path from a user action to
the score, and it already owns the version gate, the fingerprint sampling and the resync. SP4 adds one state holder
(`EditSessionController`) that opens and closes that relay and re-publishes the bridge's projection, and Compose
reads only from there. Nothing in this plan calls a JNI entry point except through the controller, and nothing calls
an op except through the relay.

**Tech Stack:** Kotlin / Jetpack Compose (Material 3), the `:FolinoEditorAndroid` Gradle module (wirelet-generated
`EditorBridgeViewModel` over `libFolinoEditorJNI.so`), swift-sheet-music's Android AARs, JUnit 4 for module tests and
`androidx.compose.ui.test` for the instrumented ones.

**Spec:** `docs/superpowers/specs/2026-08-06-android-note-editing-design.md` — §7 is this plan's subject; §4, §8 and
§10 are the constraints it works inside. Read it. The prior plans are `…-sp0.md` through `…-sp3.md` in the same
directory, and SP3's ledger is `.superpowers/sdd/2026-08-06-android-note-editing-sp3/progress.md`.

**Worktree:** `/Users/kiichi/Developer/Personal/ios-apps/Folino-iOS/.claude/worktrees/android-note-editing`, branch
`worktree-android-note-editing`. Every `git` command in this plan runs with `-C <that path>`. Do not work in the
primary checkout.

---

## Global Constraints

- **Only the vertical surface gets editing.** `ReadyScore` in `ReaderScreen.kt`. `HorizontalScore` (horizontal /
  page mode) stays read-only and carries a `PARITY(android)` marker, because iOS edits in every layout mode. Ruled
  by the user, 2026-08-15.
- **The relay owns the bridge.** `EditSessionRelay` keeps `bridge` private and exposes a named op per action. UI
  code reads state and calls the relay's ops; it must never reach the generated view model to *call* one. Task 1
  closes the last route by which it could.
- **Never re-derive an ssm rule in Kotlin.** IDs, caret rects and selection tints cross as bytes and are decoded by
  the generated codecs (`ScoreItemIDCodec`, `EditCaretFrameCodec`, `SelectionTintCodec`). Hand-decoding any of them
  is a spec §5.4 violation.
- **`String(localized:)` has no Android half.** Every user-visible string is an Android string resource under the
  repo's `module.feature.thing` key scheme, in `Android/FolinoReaderAndroid/src/main/res/values*/strings.xml`, with
  `values-ja`, `values-ko`, `values-zh-rCN` and `values-zh-rTW` translated in the same task that adds the key.
  Pitch letters C–B are **not** localized (they are the same letters everywhere; iOS says so explicitly in
  `EditorPadView.pitchKeys`).
- **Lowercase `folino` anywhere a user can read the brand.** `Folino` is developer-facing only.
- **Comment style:** reflow `//` and `///` paragraphs at 120 columns, American spelling except where an Apple or
  AndroidX API name says otherwise.
- **No save.** SP5 owns persistence, autosave, the `onPause` flush and the sibling-`.mscz` policy. SP4 edits are
  live in the session and lost when it ends; that is intended, and Task 10's device pass must not be read as a
  persistence result.

## Prerequisite: the swift-sheet-music side (landed, not yet released)

Two changes SP4 cannot build without are on ssm branch `fix/android-edit-geometry-codegen`
(`/Users/kiichi/Developer/Personal/swift-packages/wt-edit-geometry/swift-sheet-music`, off 1.14.0):

1. `feat(android): generate the editing-geometry codecs for Kotlin` (`c0fbfa51`) — moves `SelectionTintWire` /
   `EditCaretFrameWire` into `Sources/SheetMusicEditWire/Geometry` and adds an `editGeometry` codegen source set, so
   Kotlin gets `SelectionTintCodec` / `EditCaretFrameCodec` in
   `io.github.jiyimeta.sheetmusic.audio.serialization` and the models `SelectionTint` / `EditCaretFrame` in
   `io.github.jiyimeta.sheetmusic.audio.model`. Without it Tasks 4 and 5 have no payload to build or read.
2. `fix(android): refuse a layout that an edit overtook` (`60c5519a`) — the per-handle generation in
   `LayoutDocumentCache`. SP0 found this race and SP4 is what makes it reachable: a scroll-driven relayout
   overlapping a tap could otherwise hand `nativeEditingHitTest` a layout of the pre-edit score, and the ID it
   returns becomes the target of the next edit.

**Before Task 1**, path-pin this worktree at that ssm checkout and publish its AARs, then re-verify the pin:

```bash
~/.claude/bin/ssm-local-pin.sh \
  /Users/kiichi/Developer/Personal/ios-apps/Folino-iOS/.claude/worktrees/android-note-editing \
  --path /Users/kiichi/Developer/Personal/swift-packages/wt-edit-geometry/swift-sheet-music
env -C /Users/kiichi/Developer/Personal/ios-apps/Folino-iOS/.claude/worktrees/android-note-editing/Packages/Features/Editor \
  xcodebuild -list | grep sheet-music
```

The grep must print the worktree path and `@ local`. **Do not trust the script's success message** — it can report
a pin it did not write (see `reference_ssm_local_pin_verify_release_flow`); the resolved-packages line is the only
evidence. Publish all three AARs together from the ssm worktree
(`Android/gradlew :SheetMusicAndroid:publishToMavenLocal :SheetMusicAudioAndroid:publishToMavenLocal
:SheetMusicComposeAndroid:publishToMavenLocal`) and rebuild `libFolinoEditorJNI.so` and `libFolinoReaderJNI.so`
against it, or the §8.1 version gate refuses every session.

**The six pin files stay out of every commit in this plan.** They go back to `exact:` when ssm is released, and that
re-pin is its own one-line commit.

## File Structure

New, in `Android/FolinoEditorAndroid/src/main/kotlin/com/keynumber/folino/editor/`:

| File | Responsibility |
| --- | --- |
| `EditProjection.kt` | The read-only view of the bridge's `StateFlow`s, so `GeneratedEditBridging.vm` can go private. |
| `EditSessionController.kt` | Opens / closes the relay, owns `EditUiState`, exposes ops. The only thing Compose talks to. |
| `EditGeometry.kt` | Tap → `ScoreItemID` bytes, and caret item → document-mm rect. Wraps the two ssm JNI calls. |

New, in `Android/FolinoReaderAndroid/src/main/kotlin/com/keynumber/folino/reader/editing/`:

| File | Responsibility |
| --- | --- |
| `EditingTopBar.kt` | The contextual app-bar actions (undo / redo / ✓). |
| `EditingBottomBar.kt` | Voice selector + pad toggle + ← / →. |
| `EditingPad.kt` | The durations / dot / pitch-letter keys, width-adaptive. |
| `EditingCallout.kt` | The length summary and pitch chevrons pinned to the selection. |
| `EditingOverlay.kt` | The caret bar drawn over the score. |
| `MusicGlyphs.kt` | Bravura typeface access + the SMuFL codepoints the pad and callout draw. |

Modified: `ReaderScreen.kt` (chrome swap, tap routing, overlay), `ReaderViewModel.kt` (`EditSessionHost`, the edit
revision that drives a recompute, the tinted re-encode), `EditSessionRelay.kt` (Task 1),
`Android/app/src/main/kotlin/com/keynumber/folino/MainActivity.kt` (composition root),
`Android/FolinoReaderAndroid/build.gradle.kts` (module dependency), `strings.xml` × 5.

---

### Task 1: Close SP3's two parked defects

SP3 finished with two things it deliberately left for whoever drove the relay first. Both are now reachable, so they
go before any UI exists to reach them.

**Files:**
- Modify: `Android/FolinoEditorAndroid/src/main/kotlin/com/keynumber/folino/editor/EditSessionRelay.kt`
- Create: `Android/FolinoEditorAndroid/src/main/kotlin/com/keynumber/folino/editor/EditProjection.kt`
- Test: `Android/FolinoEditorAndroid/src/test/kotlin/com/keynumber/folino/editor/EditSessionRelayTest.kt`

**Interfaces:**
- Consumes: `EditBridging`, `EditNatives`, `EditSessionHost` (all unchanged from SP3).
- Produces: `interface EditProjection` with the `StateFlow`s Task 2 collects; `GeneratedEditBridging.vm` becomes
  `private`; `EditSessionRelay` gains no new public surface.

- [ ] **Step 1: Write the failing test for the drain-and-resync**

The `check(...)` in `replay()` crashes on a violated cross-image invariant, in a file whose policy everywhere else
is "answer a disagreement with a resync or a read-only close". Kotlin's `check` is not stripped in release, so it is
the one path in this file that can kill the app — and it detects a proxy (the counter) rather than the hazard (a
frame stranded in the relay queue), and repairs nothing. Add to `EditSessionRelayTest`:

```kotlin
@Test
fun `an undo that stranded a frame resyncs instead of crashing`() {
    val bridge = FakeBridging()
    val natives = FakeNatives()
    val relay = EditSessionRelay(bridge, FakeHost(), natives)
    relay.open("/score.mscx", "/scores", "id")

    // The contract `replay` guards: an undo must move the revision WITHOUT emitting an intent. Break it.
    bridge.onUndo = {
        bridge.revision += 1
        bridge.appliedIntentCount += 1
        bridge.queuedFrames += byteArrayOf(9)
    }
    val resyncsBefore = relay.resyncCount

    relay.undo()

    assertEquals(resyncsBefore + 1, relay.resyncCount)
    assertTrue("the stranded frame must be dropped, not replayed", bridge.takeRelayFrames().isEmpty())
}
```

- [ ] **Step 2: Run it and watch it die rather than fail**

```bash
Android/gradlew -p Android :FolinoEditorAndroid:testDebugUnitTest --tests "*EditSessionRelayTest*"
```

Expected: `IllegalStateException: undo/redo must not count as an applied intent`. That is the point — the current
code's answer to this is a crash.

- [ ] **Step 3: Replace the check with a drain-and-resync**

In `replay()`, delete the `check(...)` line and its comment block, and put this in its place:

```kotlin
        // An undo must move the score WITHOUT emitting an intent (`EditorBridge`'s "Undo / redo" note). If one
        // ever did, the frame would sit in the queue and the next resync — which re-encodes an authoritative score
        // that already contains that edit — would apply it a second time. Answer it the way every other
        // cross-image disagreement in this file is answered: drop what is stranded and rebuild the mirror. A
        // `check` here would instead crash the app in release, over an invariant the user cannot influence.
        val stranded = bridge.takeRelayFrames()
        if (stranded.isNotEmpty()) {
            Log.w(TAG, "undo/redo emitted ${stranded.size} intent frame(s); resyncing rather than replaying them")
            resync()
            host.requestRelayout()
            return
        }
```

- [ ] **Step 4: Run the test again**

Same command. Expected: PASS, and the other 15 `EditSessionRelayTest` cases still pass.

- [ ] **Step 5: Write the projection interface and make `vm` private**

`GeneratedEditBridging.vm` is public so SP4 can collect the projection `StateFlow`s — and that is also the last way
UI code could call an op directly and strand its frames. Close it structurally. Create `EditProjection.kt`:

```kotlin
package com.keynumber.folino.editor

import com.keynumber.folino.editor.generated.EditorBridgeViewModel
import kotlinx.coroutines.flow.StateFlow

/**
 * Everything Compose reads, and nothing it can write.
 *
 * The generated view model publishes both the projection and the ops on one object, so handing it to the UI hands
 * over the ops too — and an op applied outside [EditSessionRelay] leaves its intent frames in the queue for the
 * next relayed op to pick up, which a resync in between turns into a double-apply. There is no way to make that
 * safe from the outside, so the view model does not leave this file: [GeneratedEditBridging] implements this
 * interface over it and keeps the reference private.
 *
 * These flows are for DISPLAY. The relay reads `revision` / `appliedIntentCount` through synchronous ops instead,
 * for the reason `GeneratedEditBridging` documents at length — do not route control flow through here.
 */
interface EditProjection {
    val isSessionActive: StateFlow<Boolean>
    val revision: StateFlow<Int>
    val selectionRevision: StateFlow<Int>
    val canUndo: StateFlow<Boolean>
    val canRedo: StateFlow<Boolean>
    val hasEditTarget: StateFlow<Boolean>
    val isNoteSelected: StateFlow<Boolean>
    val hasSelectionCallout: StateFlow<Boolean>
    val canWriteRest: StateFlow<Boolean>
    val canTie: StateFlow<Boolean>
    val isSelectionTied: StateFlow<Boolean>
    val canAppendTiedNote: StateFlow<Boolean>
    val isCaretInTuplet: StateFlow<Boolean>
    val armedDurationKind: StateFlow<Int>
    val armedDots: StateFlow<Int>
    val isAddToChordArmed: StateFlow<Boolean>
    val armedTuplet: StateFlow<Int>
    val calloutDurationKind: StateFlow<Int>
    val calloutDots: StateFlow<Int>
    val activeVoice: StateFlow<Int>
    val selectedItemFrame: StateFlow<EditBytesWire?>
    val caretItemFrame: StateFlow<EditBytesWire?>
}
```

In `EditSessionRelay.kt`, change the class declaration to
`class GeneratedEditBridging(private val vm: EditorBridgeViewModel) : EditBridging, EditProjection` and implement
each member as `override val <name> get() = vm.<name>`.

- [ ] **Step 6: Verify the module still builds and the suite is green**

```bash
Android/gradlew -p Android :FolinoEditorAndroid:testDebugUnitTest --rerun-tasks
```

Expected: BUILD SUCCESSFUL, 16 tests, 0 failures. Confirm the count in
`Android/FolinoEditorAndroid/build/test-results/testDebugUnitTest/*.xml` rather than trusting "SUCCESSFUL" — a
Gradle test task that ran nothing also succeeds.

- [ ] **Step 7: Commit**

```bash
git -C .claude/worktrees/android-note-editing add Android/FolinoEditorAndroid
git -C .claude/worktrees/android-note-editing commit -m "fix(android/editor): answer a stranded undo frame with a resync, not a crash"
```

---

### Task 2: The session controller

One state holder between Compose and the relay. It exists so that "is a session open, and what does the score look
like right now" is answered in one place, and so that `OpenResult` — which has five failure cases — becomes a single
enum the UI can render.

**Files:**
- Create: `Android/FolinoEditorAndroid/src/main/kotlin/com/keynumber/folino/editor/EditSessionController.kt`
- Test: `Android/FolinoEditorAndroid/src/test/kotlin/com/keynumber/folino/editor/EditSessionControllerTest.kt`

**Interfaces:**
- Consumes: `EditSessionRelay`, `EditProjection`, `OpenResult` (Task 1).
- Produces: `EditSessionController` with `val ui: StateFlow<EditUiState>`, `fun begin(...)`, `fun end()`, and one
  method per pad / callout / bar action, each delegating to the relay.

- [ ] **Step 1: Write the failing test**

```kotlin
class EditSessionControllerTest {
    @Test
    fun `a refused open leaves the session read-only with a reason`() {
        val relay = FakeRelay(openResult = OpenResult.VERSION_SKEW)
        val controller = EditSessionController(relay, FakeProjection(), scope)

        controller.begin("/score.mscx", "/scores", "id")

        assertEquals(EditAvailability.UNAVAILABLE_VERSION_SKEW, controller.ui.value.availability)
        assertFalse(controller.ui.value.isEditing)
    }

    @Test
    fun `a resync that could not converge is read-only too, not a live session`() {
        // `open()` returns RESYNC_FAILED for a session it already had to close — the routine second session over
        // any score reaches it. Reporting it as OPENED hands the UI a live-looking session whose every op no-ops.
        val relay = FakeRelay(openResult = OpenResult.RESYNC_FAILED)
        val controller = EditSessionController(relay, FakeProjection(), scope)

        controller.begin("/score.mscx", "/scores", "id")

        assertEquals(EditAvailability.UNAVAILABLE_DIVERGED, controller.ui.value.availability)
        assertFalse(controller.ui.value.isEditing)
    }
}
```

- [ ] **Step 2: Run it**

```bash
Android/gradlew -p Android :FolinoEditorAndroid:testDebugUnitTest --tests "*EditSessionControllerTest*"
```

Expected: FAIL — `Unresolved reference: EditSessionController`.

- [ ] **Step 3: Write the controller**

```kotlin
package com.keynumber.folino.editor

/** Why editing is or is not available, in the terms the UI has to explain to a user. */
enum class EditAvailability {
    /** A session is open and every op is live. */
    AVAILABLE,

    /** Folino's engine and the one behind the score handle are different builds (§8.1). Editing cannot be safe. */
    UNAVAILABLE_VERSION_SKEW,

    /** The two copies of the score disagreed and could not be reconciled — `open()` closed the session itself. */
    UNAVAILABLE_DIVERGED,

    /** No score handle, or the file would not parse. */
    UNAVAILABLE_NO_SCORE,
}

data class EditUiState(
    val isEditing: Boolean = false,
    val availability: EditAvailability = EditAvailability.AVAILABLE,
    val canUndo: Boolean = false,
    val canRedo: Boolean = false,
    val hasEditTarget: Boolean = false,
    val isNoteSelected: Boolean = false,
    val hasSelectionCallout: Boolean = false,
    val canWriteRest: Boolean = false,
    val armedDurationKind: Int = 0,
    val armedDots: Int = 0,
    val activeVoice: Int = 0,
    val isPadVisible: Boolean = false,
    val selectedItem: ByteArray? = null,
    val caretItem: ByteArray? = null,
    /** Bumped by the relay's own revision; the render surface keys its re-encode off this. */
    val revision: Int = 0,
)
```

The class itself: `begin(...)` calls `relay.open(...)` and maps `OpenResult` to `EditAvailability`
(`OPENED` → `AVAILABLE` + `isEditing = true`; `VERSION_SKEW` → `UNAVAILABLE_VERSION_SKEW`; `RESYNC_FAILED` →
`UNAVAILABLE_DIVERGED`; `NO_HANDLE` / `SCORE_UNREADABLE` / `MIRROR_REFUSED` → `UNAVAILABLE_NO_SCORE`). `end()`
calls `relay.close()` and resets `ui` to its default. Every op method is one line —
`fun inputPitch(letter: String) = relay.inputPitch(letter)` — and there are no others: a branch here is a rule
Android would have and iOS would not.

`ui` combines the projection flows into `EditUiState`. `isPadVisible` is controller-local (a UI disclosure, not
engine state) and defaults to closed, exactly as on iOS.

- [ ] **Step 4: Run the tests**

Same command. Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git -C .claude/worktrees/android-note-editing add Android/FolinoEditorAndroid
git -C .claude/worktrees/android-note-editing commit -m "feat(android/editor): hold the session's state where Compose can read it"
```

---

### Task 3: Wire the module in and let an edit drive a relayout

The Reader owns the score handle, so it is what implements `EditSessionHost` — and the recompute loop has to learn
that an edit is a reason to run.

**Files:**
- Modify: `Android/FolinoReaderAndroid/build.gradle.kts`
- Modify: `Android/FolinoReaderAndroid/src/main/kotlin/com/keynumber/folino/reader/ReaderViewModel.kt`
- Test: `Android/FolinoReaderAndroid/src/test/kotlin/com/keynumber/folino/reader/ReaderEditHostTest.kt`

**Interfaces:**
- Consumes: `EditSessionHost` (SP3).
- Produces: `ReaderViewModel : EditSessionHost` with `scoreHandle()`, `replaceScoreHandle(handle)`,
  `requestRelayout()`, plus `val editRevision: StateFlow<Int>` for the recompute loop.

- [ ] **Step 1: Add the dependency**

In `Android/FolinoReaderAndroid/build.gradle.kts`, inside `dependencies`:

```kotlin
    // The edit session (SP3): the relay, its host contract, and the generated bridge. The Reader owns the score
    // handle the mirror session lives beside, so it is what implements EditSessionHost.
    api(project(":FolinoEditorAndroid"))
```

- [ ] **Step 2: Write the failing test**

```kotlin
@Test
fun `an edit revision bump drives a recompute`() = runTest {
    val vm = ReaderViewModel(app)
    vm.setLayoutOptions(LayoutOptions())
    vm.setLayoutWidthMm(180.0)
    val generationBefore = vm.layoutGeneration.value

    vm.requestRelayout()
    advanceUntilIdle()

    assertTrue(vm.layoutGeneration.value > generationBefore)
}
```

- [ ] **Step 3: Run it**

```bash
Android/gradlew -p Android :FolinoReaderAndroid:testDebugUnitTest --tests "*ReaderEditHostTest*"
```

Expected: FAIL — `Unresolved reference: requestRelayout`.

- [ ] **Step 4: Implement the host on the view model**

Add `private val _editRevision = MutableStateFlow(0)` and fold it into `startRecomputeLoop`'s `combine` as a fifth
input, so a bump re-fires the loop with the same handle and options. Then:

```kotlin
    // MARK: - EditSessionHost

    override fun scoreHandle(): Long = _scoreHandle.value ?: 0L

    /**
     * The relay calls `nativeReleaseScore(stale)` on the very next line, so every use of the previous handle has to
     * be gone before this returns — a render pass queued onto another thread or a coroutine that will read it next
     * frame is a use-after-free, not a stale read. `mapLatest` in the recompute loop cancels the in-flight compute
     * cooperatively, which is NOT synchronous, so the old handle is retained across the swap and released only
     * after `layoutMutex` has been taken: holding that lock is what proves no native call is mid-flight.
     */
    override fun replaceScoreHandle(handle: Long) {
        runBlocking {
            layoutMutex.withLock {
                _scoreHandle.value = handle
            }
        }
    }

    override fun requestRelayout() {
        _editRevision.value += 1
    }
```

Also drop `RECOMPUTE_DEBOUNCE_MS` for an edit-driven pass: an edit is one discrete user action, and 
`delay(RECOMPUTE_DEBOUNCE_MS)` between the keystroke and the note appearing is exactly the lag the debounce exists
to prevent elsewhere. Gate it: `if (!editDriven) delay(RECOMPUTE_DEBOUNCE_MS)`.

- [ ] **Step 5: Run the test**

Same command. Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git -C .claude/worktrees/android-note-editing add Android/FolinoReaderAndroid
git -C .claude/worktrees/android-note-editing commit -m "feat(android/reader): host the edit session's score handle"
```

---

### Task 4: Tap → hit test → selection

**Files:**
- Create: `Android/FolinoEditorAndroid/src/main/kotlin/com/keynumber/folino/editor/EditGeometry.kt`
- Modify: `Android/FolinoReaderAndroid/src/main/kotlin/com/keynumber/folino/reader/ReaderScreen.kt` (the
  `ReadyScore` tap `pointerInput`, around line 1272)
- Test: `Android/FolinoEditorAndroid/src/test/kotlin/com/keynumber/folino/editor/EditGeometryTest.kt`

**Interfaces:**
- Produces: `fun editingHitTestForTap(tap: Offset, contentOffsetPx: Offset, pxPerMM: Float, scale: Float,
  scoreHandle: Long, activeVoice: Int, layoutOptionsBytes: ByteArray): ByteArray?` and
  `fun caretRectMm(scoreHandle: Long, itemBytes: ByteArray, minimumWidthMm: Double): EditCaretFrame?`.

- [ ] **Step 1: Write the failing test**

The px→mm conversion is the part worth pinning; the JNI call is not mockable off-device, so the test drives the
arithmetic through a seam:

```kotlin
@Test
fun `a tap converts to document millimetres the same way the seek path does`() {
    val mm = tapToDocumentMm(
        tap = Offset(100f, 260f),
        contentOffsetPx = Offset(-20f, 40f),
        pxPerMM = 4f,
        scale = 2f,
    )
    assertEquals(15.0, mm.first, 1e-9)
    assertEquals(27.5, mm.second, 1e-9)
}

@Test
fun `a degenerate scale yields no point rather than an infinity`() {
    assertNull(tapToDocumentMmOrNull(Offset.Zero, Offset.Zero, pxPerMM = 4f, scale = 0f))
}
```

- [ ] **Step 2: Run it**

```bash
Android/gradlew -p Android :FolinoEditorAndroid:testDebugUnitTest --tests "*EditGeometryTest*"
```

Expected: FAIL — `Unresolved reference: tapToDocumentMm`.

- [ ] **Step 3: Write `EditGeometry.kt`**

The conversion is lifted verbatim from `TapToCursor.kt` — the same viewport arithmetic, because it is the same tap
in the same space, and two spellings of it would drift apart the first time the viewport changes:

```kotlin
/** Tap point (outer viewport px) → document millimetres. Mirrors `nearestCursorForTap`'s conversion exactly. */
fun tapToDocumentMm(tap: Offset, contentOffsetPx: Offset, pxPerMM: Float, scale: Float): Pair<Double, Double> =
    Pair(
        ((tap.x - contentOffsetPx.x) / (pxPerMM * scale)).toDouble(),
        ((tap.y - contentOffsetPx.y) / (pxPerMM * scale)).toDouble(),
    )

/**
 * Tap → the `ScoreItemID` bytes an edit intent addresses, or null when the tap hit paper.
 *
 * Null is a real answer, not a failure: ssm's hit-test policy answers "nothing" for a tap that is not on a staff
 * band, and iOS uses exactly that to mean "deselect". An empty array also comes back when the layout is not
 * cached — which, since ssm 1.14.x, is what a relayout overtaken by an edit deliberately leaves behind. Treat it
 * the same way: the tap does nothing and the recompute already in flight will make the next one work.
 */
fun editingHitTestForTap(...): ByteArray? { ... }
```

`caretRectMm` calls `SheetMusicJNI.nativeEditingCaretFrame(handle, itemBytes, minimumWidthMm)` and decodes with
`EditCaretFrameCodec.decode(...)`, returning null on an empty array.

- [ ] **Step 4: Run the test**

Same command. Expected: PASS.

- [ ] **Step 5: Route the vertical surface's tap**

In `ReadyScore`'s tap `pointerInput`, add `editing` to the key list and branch at the top of `detectTapGestures`:

```kotlin
                detectTapGestures { offset ->
                    if (editing.isEditing) {
                        // Editing replaces tap-to-seek on this surface: the same tap cannot both move the
                        // playhead and pick an element to edit, and iOS makes the same choice.
                        val bytes = editingHitTestForTap(
                            tap = offset,
                            contentOffsetPx = Offset(-viewport.offsetX, vPadPx - viewport.offsetY),
                            pxPerMM = fitPxPerMM,
                            scale = viewport.scale,
                            scoreHandle = handle,
                            activeVoice = editing.activeVoice,
                            layoutOptionsBytes = optionsBytes,
                        )
                        editing.onSelectItem(bytes)
                        return@detectTapGestures
                    }
                    val cursor = nearestCursorForTap(...) ?: return@detectTapGestures
                    audioVm.handleTap(cursor)
                }
```

`onSelectItem(null)` must reach the controller too — that is the deselect.

- [ ] **Step 6: Build and commit**

```bash
Android/gradlew -p Android :FolinoReaderAndroid:compileDebugKotlin
git -C .claude/worktrees/android-note-editing add Android
git -C .claude/worktrees/android-note-editing commit -m "feat(android/editor): turn a tap on the score into an editing selection"
```

---

### Task 5: Selection tint and the caret overlay

**Files:**
- Modify: `Android/FolinoReaderAndroid/src/main/kotlin/com/keynumber/folino/reader/ReaderViewModel.kt`
- Create: `Android/FolinoReaderAndroid/src/main/kotlin/com/keynumber/folino/reader/editing/EditingOverlay.kt`
- Test: `Android/FolinoReaderAndroid/src/test/kotlin/com/keynumber/folino/reader/EditSelectionTintTest.kt`

**Interfaces:**
- Produces: `ReaderViewModel.setEditSelection(ids: List<ScoreItemID>, argb: UInt)`, which re-encodes the **cached**
  layout; `@Composable fun EditingCaretOverlay(rectMm: EditCaretFrame?, pxPerMM: Float, scale: Float, offset: Offset)`.

- [ ] **Step 1: Write the failing test**

```kotlin
@Test
fun `selecting a note re-encodes without laying out again`() = runTest {
    val vm = ReaderViewModel(app)
    // ... load a score, let the recompute loop settle ...
    val generationBefore = vm.layoutGeneration.value

    vm.setEditSelection(listOf(noteId), argb = 0xFF3366CCu)
    advanceUntilIdle()

    // A new program, but NOT a new layout: re-engraving the score on every selection change is the cost this
    // whole entry point exists to avoid, and it would also move every rect the caret is positioned from.
    assertEquals(generationBefore, vm.layoutGeneration.value)
    assertNotEquals(programBefore, (vm.state.value as ReaderState.Ready).program)
}
```

- [ ] **Step 2: Run it**

```bash
Android/gradlew -p Android :FolinoReaderAndroid:testDebugUnitTest --tests "*EditSelectionTintTest*"
```

Expected: FAIL — `Unresolved reference: setEditSelection`.

- [ ] **Step 3: Implement the re-encode**

```kotlin
    /**
     * Recolours the selected items in the CACHED layout — `nativeEncodeDrawProgram` never relayouts, which is why
     * selecting a note does not re-engrave the score (and why every caret rect stays where it was).
     *
     * An empty selection reproduces `nativeComputeLayout`'s bytes exactly, so clearing is the same call.
     * An empty RESULT means there is no cached layout: the recompute loop has not run for this handle yet, or an
     * edit overtook the one that had. Leave the current program alone and wait — the loop is already on its way.
     */
    fun setEditSelection(ids: List<ScoreItemID>, argb: UInt) {
        viewModelScope.launch {
            val handle = _scoreHandle.value ?: return@launch
            val bytes = layoutMutex.withLock {
                withContext(Dispatchers.Default) {
                    SheetMusicJNI.nativeEncodeDrawProgram(handle, SelectionTintCodec.encode(SelectionTint(argb, ids)))
                }
            }
            if (bytes.isEmpty()) return@launch
            _state.value = ReaderState.Ready(DrawProgramReader.decode(bytes))
        }
    }
```

- [ ] **Step 4: Run the test**

Same command. Expected: PASS.

- [ ] **Step 5: Draw the caret**

`EditingOverlay.kt` converts the document-mm rect into the same px space the score is drawn in and fills it:

```kotlin
    Canvas(Modifier.fillMaxSize()) {
        val r = rectMm ?: return@Canvas
        drawRect(
            color = caretColor,
            topLeft = Offset(
                (r.xMm * pxPerMM * scale).toFloat() + offset.x,
                (r.yMm * pxPerMM * scale).toFloat() + offset.y,
            ),
            size = Size((r.widthMm * pxPerMM * scale).toFloat(), (r.heightMm * pxPerMM * scale).toFloat()),
            // Multiply so the bar reads as being BEHIND the notation rather than painted over it — a caret that
            // hides the notehead it sits next to is worse than no caret. Spec §7.
            blendMode = BlendMode.Multiply,
        )
    }
```

Mount it inside the same `graphicsLayer`-backed node the score content uses, so panning moves the caret with the
score instead of leaving it pinned to the viewport.

- [ ] **Step 6: Commit**

```bash
git -C .claude/worktrees/android-note-editing add Android
git -C .claude/worktrees/android-note-editing commit -m "feat(android/reader): tint the selection and draw the caret"
```

---

### Task 6: The contextual app bar and the bottom bar

**Files:**
- Create: `Android/FolinoReaderAndroid/src/main/kotlin/com/keynumber/folino/reader/editing/EditingTopBar.kt`
- Create: `Android/FolinoReaderAndroid/src/main/kotlin/com/keynumber/folino/reader/editing/EditingBottomBar.kt`
- Modify: `ReaderScreen.kt` (`ReaderTopBar`, around line 959, and the transport row)
- Modify: `Android/FolinoReaderAndroid/src/main/res/values*/strings.xml` (5 files)

- [ ] **Step 1: Add the strings**

In `values/strings.xml`:

```xml
    <string name="reader_editing_start">Edit notes</string>
    <string name="reader_editing_done">Done</string>
    <string name="reader_editing_undo">Undo</string>
    <string name="reader_editing_redo">Redo</string>
    <string name="reader_editing_pad">Note pad</string>
    <string name="reader_editing_voice">Voice %1$d</string>
    <string name="reader_editing_unavailable_version">Editing is unavailable: this score is being rendered by a different engine build.</string>
    <string name="reader_editing_unavailable_diverged">Editing is unavailable for this score right now.</string>
```

Translate all eight into `values-ja`, `values-ko`, `values-zh-rCN`, `values-zh-rTW` in this step, not later — a key
added without its translations ships English to four locales.

- [ ] **Step 2: Swap the app-bar actions while editing**

`ReaderTopBar` gains `editing: EditUiState` and, when `editing.isEditing`, replaces its `actions` block with undo /
redo / ✓. Undo and redo are `enabled = editing.canUndo` / `canRedo`; ✓ calls `onEndEditing`. The back arrow ends the
session too, flushing nothing (SP5 owns saving) — and system back must do the same, via a `BackHandler(enabled =
editing.isEditing)`.

- [ ] **Step 3: Add the bottom bar**

A fixed row above the transport carrying the voice selector (1–4, `setActiveVoice`), the pad toggle, and ← / →
(`selectPreviousElement` / `selectNextElement`). ← / → sit here rather than in the pad because iOS puts them beside
the transport for the same reason: they survive the pad being closed and cost it no row.

- [ ] **Step 4: Verify by preview**

Add a `@Preview` for each composable and check them in Android Studio, or capture with the existing screenshot
harness. Confirm the editing bar replaces — not overlaps — the reading actions.

- [ ] **Step 5: Commit**

```bash
git -C .claude/worktrees/android-note-editing add Android
git -C .claude/worktrees/android-note-editing commit -m "feat(android/reader): swap in the editing chrome"
```

---

### Task 7: The pad

**Files:**
- Create: `Android/FolinoReaderAndroid/src/main/kotlin/com/keynumber/folino/reader/editing/EditingPad.kt`
- Create: `Android/FolinoReaderAndroid/src/main/kotlin/com/keynumber/folino/reader/editing/MusicGlyphs.kt`
- Test: `Android/FolinoReaderAndroid/src/test/kotlin/com/keynumber/folino/reader/editing/PadDurationKindTest.kt`

- [ ] **Step 1: Write the failing test for the arming vocabulary**

`armDuration(kind:)` takes `NoteDurationWire`'s discriminator, and **silently ignores kind 11 (`.fraction`)** —
it is emit-only. A pad key built from the emit-side vocabulary is a no-op, so pin the mapping:

```kotlin
@Test
fun `the pad arms only the kinds the bridge accepts`() {
    assertEquals(listOf(1, 2, 3, 4, 5), PadDuration.ordered.map { it.kind })
    assertTrue(PadDuration.ordered.none { it.kind == 11 })
}
```

- [ ] **Step 2: Run it**

```bash
Android/gradlew -p Android :FolinoReaderAndroid:testDebugUnitTest --tests "*PadDurationKindTest*"
```

Expected: FAIL — `Unresolved reference: PadDuration`.

- [ ] **Step 3: Write the pad**

Two rows, split by job exactly as iOS splits them (`EditorPadView`): row 1 arms or re-times (durations, tuplet slot,
dot), row 2 acts (C–B, then the rest key). The one-row layout iOS offers on a wide iPad is chosen **by measured
width, not by a size class** — an iPad mini is "regular" and 400 pt narrower, and the one-row layout ran off both
ends there. Compose's equivalent of `ViewThatFits` is `BoxWithConstraints`: offer the single row when
`maxWidth >= singleRowMinWidth`, stack otherwise.

Glyphs come from Bravura. `rememberBravuraTypeface()` already exists in `DisplayInspectorSheet.kt`; move it into
`MusicGlyphs.kt` and have both call sites use it rather than growing a second copy.

The whole card goes inert when `!hasEditTarget` or playback is running — greying the card, not each key, is what
says the pad is asleep rather than broken.

- [ ] **Step 4: Run the test and check the preview**

Same command, then render `@Preview` at 360 dp and 840 dp and confirm the row split flips between them.

- [ ] **Step 5: Commit**

```bash
git -C .claude/worktrees/android-note-editing add Android
git -C .claude/worktrees/android-note-editing commit -m "feat(android/reader): add the note-input pad"
```

---

### Task 8: The callout

**Files:**
- Create: `Android/FolinoReaderAndroid/src/main/kotlin/com/keynumber/folino/reader/editing/EditingCallout.kt`
- Modify: `ReaderScreen.kt` (mount it over the score)

- [ ] **Step 1: Position it from the caret frame**

The callout is pinned to the selected item, whose rect comes from `caretRectMm(handle, selectedItemFrame, …)` —
the same call the caret overlay makes, with the selection's ID instead of the caret's. Convert to px in the score's
space, then clamp into the viewport so a selection near an edge does not push the card off-screen.

- [ ] **Step 2: Draw the two things it carries**

The length summary (from `calloutDurationKind` / `calloutDots`, tapping it opens a length tray that calls
`setSelectionDuration` / `setSelectionDots`) and the pitch chevrons (`shiftPitch(+1)` / `shiftPitch(-1)`, with a long
press stepping an octave via `shiftOctave`). Chevrons rather than ♯/♭ for iOS's stated reason: what they do is step,
in whatever spelling the key signature calls for, and a ♯ button that sometimes produces a ♮ reads as broken.

A rest gets the same card minus the chevrons — `isNoteSelected` is the switch. The tie key is second-pass; leave the
slot and do not draw it.

- [ ] **Step 3: Mount it only while there is a selection**

`hasSelectionCallout` gates it. There is no empty state.

- [ ] **Step 4: Commit**

```bash
git -C .claude/worktrees/android-note-editing add Android
git -C .claude/worktrees/android-note-editing commit -m "feat(android/reader): float the editing callout beside the selection"
```

---

### Task 9: Compose the whole thing at the app layer, and mark the gap

**Files:**
- Modify: `Android/app/src/main/kotlin/com/keynumber/folino/MainActivity.kt` (the `ReaderScreen(` call, ~line 654)
- Modify: `ReaderScreen.kt` (the `HorizontalScore` branch)

- [ ] **Step 1: Build the controller at the composition root**

`MainActivity` is the only layer that sees both the JNI bridge and the Reader, so it constructs
`EditorRoomFiles()` → the generated view model → `GeneratedEditBridging` → `EditSessionRelay(bridge, readerVm)` →
`EditSessionController`, and passes the controller down. Nothing below constructs a bridge.

- [ ] **Step 2: Refuse to open a session on a PDF**

A PDF item has no editable `Score`; edit mode stays unavailable there, exactly as on iOS. Gate the "Edit notes"
action on the same signal the Reader already uses to know it is showing a PDF.

- [ ] **Step 3: Mark the layout-mode gap**

Above the `HorizontalScore` call site:

```kotlin
// PARITY(android): note editing in page mode — editing is offered on the vertical surface only. iOS edits in
//   every layout mode (`ReaderRootScreen` has no mode gate); Android's horizontal/page surface routes its taps
//   through a separate paged-fetch path that would need its own hit-test, caret and tint wiring. Entering edit
//   mode from page mode is refused rather than silently doing nothing.
```

Then run `Scripts/parity-report.py` so `docs/engineering/ios-android-parity.md` picks the row up — the
`parity-ledger` pre-commit hook fails if it drifted.

- [ ] **Step 4: Build the app**

```bash
Android/gradlew -p Android :app:assembleDebug
```

Expected: BUILD SUCCESSFUL.

- [ ] **Step 5: Commit**

```bash
git -C .claude/worktrees/android-note-editing add Android docs
git -C .claude/worktrees/android-note-editing commit -m "feat(android): let the Reader open a note-editing session"
```

---

### Task 10: Instrumented smoke, then the device pass

**Files:**
- Create: `Android/app/src/androidTest/kotlin/com/keynumber/folino/editor/EditingUiTest.kt`

- [ ] **Step 1: Write the instrumented test**

Drive the real UI on a device: open a score, enter edit mode, tap a note, assert the callout appears, arm a
duration, write a pitch, assert `canUndo`, undo, assert the score's fingerprint returns to where it started. Use
`runOnMainSync` for anything that reads the relay — SP3's whole-branch review found a Critical that only reproduced
on the production thread, and an instrumentation-thread test won the race and reported green.

- [ ] **Step 2: Run it on the physical Pixel 8a**

```bash
Android/gradlew -p Android :app:connectedDebugAndroidTest
```

Expected: 0 failures. Confirm from
`Android/app/build/outputs/androidTest-results/connected/**/*.xml`, not from Gradle's exit status.

- [ ] **Step 3: Hand it to the user**

Editing is gesture- and latency-sensitive; the final gate is the user on the physical device, as it was for
annotation Phase 2 and for SP3. Install, launch, and ask them to write a bar, delete a note, undo twice, redo, and
switch voices — and to say whether it *feels* right, which is the part no test covers.

- [ ] **Step 4: Report before anything is released**

SP4 is what first exercises the two unreleased ssm commits. Once the device pass is clean, surface — in one message,
before any tag — everything found along the way, including anything deliberately left alone, so the ssm release can
absorb it. Then re-pin Folino from the path pin to the new version as its own commit.

---

## Self-review

**Spec coverage.** §7's six elements each have a task: contextual app bar and bottom bar (6), pad (7), callout (8),
caret overlay (5), selection tint (5), ← / → beside the transport (6). §8.1's version gate and §8.3's divergence
handling arrive as `EditAvailability` in Task 2 — SP3 implemented the mechanisms, SP4 only has to render their
outcome. §10's v1 scope is covered except the deliberate second-pass items (chords, ties, tuplets, explicit
accidentals, audition, hover), whose ops exist and are simply not drawn. §8.4 and the save path are SP5's.

**Known gaps this plan accepts:** page-mode editing (Task 9 marks it); the tuplet key's long-press size menu (the
`armedTuplet` projection exists, the key is second-pass); audition on input (`setPlaybackActive` is wired, the
decision to audition lives in the shared core and needs a Domain `PlaybackController` on the Android side).

**Type consistency.** `EditUiState`, `EditAvailability` and `EditProjection` are declared in Tasks 2 and 1 and used
unchanged in 4–9. `editingHitTestForTap` / `caretRectMm` are declared in Task 4 and consumed in 5 and 8.
`setEditSelection` is declared in Task 5 and called from 9. The relay's op names are SP3's and are not renamed here.
