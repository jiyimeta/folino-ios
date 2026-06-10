package com.keynumber.folino.screenshot.scenes

import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import com.keynumber.folino.reader.LayoutOptions
import com.keynumber.folino.reader.PlaybackInspectorContent
import com.keynumber.folino.reader.RepeatMode
import com.keynumber.folino.screenshot.fixtures.MarketingStrings
import com.keynumber.folino.screenshot.fixtures.ReaderSceneContent
import com.keynumber.folino.screenshot.fixtures.SCREENSHOT_STAFF_SIZE
import com.keynumber.folino.screenshot.fixtures.SceneReady
import com.keynumber.folino.screenshot.fixtures.collectAsStateCompat
import com.keynumber.folino.screenshot.fixtures.rememberPreparedAudioVm
import com.keynumber.folino.screenshot.fixtures.rememberReaderSceneState
import com.keynumber.folino.screenshot.frame.ScreenshotFrame
import com.keynumber.folino.screenshot.frame.ScreenshotLayout
import com.keynumber.folino.ui.theme.FolinoTheme

// Whole-piece-repeat scene: the score behind, with the REAL playback inspector content laid open over
// the bottom — General section AND the per-staff Mixer/Parts section — with the repeat control set to
// LOOP_ALL ("1曲リピート"), all NON-grayed.
//
// The real `PlaybackInspectorSheet` is a `ModalBottomSheet` (a separate dialog window — invisible to
// the single-node static capture) and grays every control out / shows "No parts to mix." when no audio
// engine is bound. So we drive the real production path: a live, PREPARED `ReaderAudioViewModel`
// (engine bound via ReaderPlaybackService, score decoded into mixer channels) and host the SAME
// `PlaybackInspectorContent` the production sheet uses in a bottom-aligned Surface that lives inside the
// captured tree (DRY: identical control list, real engine state). The repeat controller is installed in
// LOOP_ALL so the repeat row reads as whole-piece repeat.
@Composable
fun LoopAllScene(layout: ScreenshotLayout, tag: String) {
    val copy = MarketingStrings.forScene("LoopAll", tag)
    ScreenshotFrame(title = copy.title, subtitle = copy.subtitle, layout = layout) {
        FolinoTheme {
            val scene = rememberReaderSceneState {
                LayoutOptions.DEFAULT.copy(staffSize = SCREENSHOT_STAFF_SIZE)
            }
            val audioVm = rememberPreparedAudioVm(scene?.scoreHandle)
            // Whole-piece repeat for the repeat row. Install once the VM is prepared; the screenshot
            // needs no persistence, so the load/persist callbacks are inert.
            LaunchedEffect(audioVm) {
                audioVm?.installRepeatController(
                    initialMode = RepeatMode.LOOP_ALL,
                    loadRange = { null },
                    persistRange = {},
                    persistMode = {},
                )
            }
            Box(Modifier.fillMaxSize()) {
                if (scene != null) {
                    val openingQuarterBpm by scene.viewModel.openingQuarterBpm
                        .collectAsStateCompat(120.0)
                    ReaderSceneContent(
                        state = scene.state,
                        scoreHandle = scene.scoreHandle,
                        layoutOptions = scene.layoutOptions,
                        withCursor = false,
                        // Defer the capture gate to also wait on the prepared engine below.
                        signalReadyWhenRendered = false,
                    )
                    if (audioVm != null) {
                        // Page rendered AND engine prepared (mixer populated): release the capture gate.
                        LaunchedEffect(Unit) {
                            kotlinx.coroutines.delay(300)
                            SceneReady.signalReady()
                        }
                        // Bottom sheet stand-in: a rounded top surface, bottom-aligned, holding the real
                        // inspector content. `heightIn(max = …)` keeps it a partial overlay so the score
                        // behind it stays visible above the sheet.
                        Surface(
                            modifier = Modifier
                                .align(Alignment.BottomCenter)
                                .fillMaxWidth()
                                .heightIn(max = 420.dp),
                            shape = RoundedCornerShape(topStart = 16.dp, topEnd = 16.dp),
                            tonalElevation = 4.dp,
                            shadowElevation = 12.dp,
                            color = MaterialTheme.colorScheme.surface,
                        ) {
                            PlaybackInspectorContent(
                                audioVm = audioVm,
                                openingQuarterBpm = openingQuarterBpm,
                            )
                        }
                    }
                }
            }
        }
    }
}
