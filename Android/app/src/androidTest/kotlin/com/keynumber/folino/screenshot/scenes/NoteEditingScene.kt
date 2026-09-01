package com.keynumber.folino.screenshot.scenes

import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import com.keynumber.folino.editor.DEFAULT_TUPLET_SIZE
import com.keynumber.folino.editor.EditUiState
import com.keynumber.folino.reader.LayoutOptions
import com.keynumber.folino.reader.ReaderLayoutMode
import com.keynumber.folino.reader.ReaderTopBar
import com.keynumber.folino.reader.editing.EditingPad
import com.keynumber.folino.screenshot.fixtures.MarketingStrings
import com.keynumber.folino.screenshot.fixtures.ReaderSceneContent
import com.keynumber.folino.screenshot.fixtures.SCREENSHOT_STAFF_SIZE
import com.keynumber.folino.screenshot.fixtures.rememberReaderSceneState
import com.keynumber.folino.screenshot.frame.ScreenshotFrame
import com.keynumber.folino.screenshot.frame.ScreenshotLayout
import com.keynumber.folino.ui.theme.FolinoTheme

// Note-editing scene: the Reader mid-session — the editing top bar (undo / redo / voice / done) in place of the
// reading actions, the caret sitting in the first measure, and the note pad docked at the bottom.
//
// Everything here is the production composable, driven by static state rather than a live session. `EditingPad`
// and `ReaderTopBar` are both presentational — the pad takes its armed state as parameters and the bar takes an
// `EditUiState` — so a screenshot does not need the Editor JNI, an open session or a score mirror. That matters
// beyond convenience: an edit session writes, and a marketing capture that opens one would be mutating the
// fixture score on every run.
//
// The caret is `ReaderSceneContent`'s `withCursor` mark, not `EditingCaretOverlay`. They are the same column by
// design — see that overlay's doc: "deliberately the same accent column the playback head uses, because it means
// the same thing". Reaching for the edit overlay instead would need an `EditCaretFrame` in document millimetres,
// which only a live session can answer for, to draw pixels that are already identical.
@Composable
fun NoteEditingScene(layout: ScreenshotLayout, tag: String) {
    val copy = MarketingStrings.forScene("NoteEditing", tag)
    ScreenshotFrame(title = copy.title, subtitle = copy.subtitle, layout = layout, subtitleBullet = copy.bullet) {
        FolinoTheme {
            val scene = rememberReaderSceneState {
                LayoutOptions.DEFAULT.copy(
                    mode = ReaderLayoutMode.VERTICAL,
                    staffSize = SCREENSHOT_STAFF_SIZE,
                )
            }
            Column(Modifier.fillMaxSize()) {
                // `editing.isEditing` swaps the whole action row for the editing set, which is the point of the
                // shot: the bar has to read as "you are writing into this score", not as the reading bar with a
                // pad below it. `canUndo` + `sessionHasEdits` are on so undo and the overflow render live rather
                // than greyed — a session a user has actually typed into is what the shot is claiming.
                ReaderTopBar(
                    onBack = {},
                    onShare = {},
                    onEditInfo = {},
                    onPlaybackControls = {},
                    onDisplaySettings = {},
                    windowInsets = WindowInsets(0, 0, 0, 0),
                    editing = EditUiState(
                        isEditing = true,
                        canUndo = true,
                        canRedo = false,
                        hasEditTarget = true,
                        isNoteSelected = true,
                        sessionHasEdits = true,
                        // 0-based: the picker renders `activeVoice + 1`, so this is the "1" a fresh session shows.
                        activeVoice = 0,
                    ),
                )
                Box(Modifier.fillMaxSize().weight(1f)) {
                    if (scene != null) {
                        ReaderSceneContent(
                            state = scene.state,
                            scoreHandle = scene.scoreHandle,
                            layoutOptions = scene.layoutOptions,
                            withCursor = true,
                        )
                        // Docked at the bottom, where a real session parks it. Armed on a quarter note with the
                        // tie and chord keys live, so the pad shows its full width of keys rather than a row of
                        // dimmed ones — `hasEditTarget` is what wakes the card up.
                        Box(
                            Modifier
                                .align(Alignment.BottomCenter)
                                .fillMaxWidth()
                                .padding(horizontal = 8.dp, vertical = 12.dp),
                        ) {
                            EditingPad(
                                armedDurationKind = QUARTER_NOTE_DURATION_KIND,
                                armedDots = 0,
                                canWriteRest = true,
                                canTie = true,
                                isSelectionTied = false,
                                canAppendTiedNote = false,
                                isCaretInTuplet = false,
                                // The tuplet key wears this number, so it has to be the engine's own default
                                // rather than a 0 — an unarmed key still renders the size it would create.
                                armedTuplet = DEFAULT_TUPLET_SIZE,
                                isAddToChordArmed = false,
                                hasEditTarget = true,
                                isPlaybackActive = false,
                                onArmDuration = {},
                                onSetArmedDots = {},
                                onToggleArmedDot = {},
                                onInputPitch = {},
                                onWriteRest = {},
                                onToggleTie = {},
                                onAppendTiedNote = {},
                                onCreateTuplet = {},
                                onRemoveTuplet = {},
                                onToggleAddToChord = {},
                            )
                        }
                    }
                }
            }
        }
    }
}

// The pad's duration keys are keyed by ssm's duration kind, listed in `PadDuration.ordered`: 1 whole, 2 half,
// 3 quarter, 4 eighth, 5 sixteenth. The quarter is the one to arm — it is the length a reader recognises as
// "a note" at a glance, and it puts the lit capsule in the middle of the row rather than at an end.
private const val QUARTER_NOTE_DURATION_KIND = 3
