package com.keynumber.folino.screenshot.scenes

import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import com.keynumber.folino.reader.LayoutOptions
import com.keynumber.folino.reader.PlaybackFab
import com.keynumber.folino.reader.ReaderLayoutMode
import com.keynumber.folino.reader.ReaderTopBar
import com.keynumber.folino.screenshot.fixtures.MarketingStrings
import com.keynumber.folino.screenshot.fixtures.ReaderSceneContent
import com.keynumber.folino.screenshot.fixtures.SCREENSHOT_STAFF_SIZE
import com.keynumber.folino.screenshot.fixtures.SceneReady
import com.keynumber.folino.screenshot.fixtures.rememberPreparedAudioVm
import com.keynumber.folino.screenshot.fixtures.rememberReaderSceneState
import com.keynumber.folino.screenshot.frame.ScreenshotFrame
import com.keynumber.folino.screenshot.frame.ScreenshotLayout
import com.keynumber.folino.ui.theme.FolinoTheme

// Reader scene: the real bundled score laid out by ReaderViewModel, with a static playback cursor
// placed near the middle of the first measure (pure JNI hit-test). On top, the seek-bar-OFF transport
// affordance — the REAL `PlaybackFab` cluster from ReaderScreen, driven by a live, PREPARED
// `ReaderAudioViewModel` — so both the jump-to-start SmallFAB and the play/pause FAB render enabled.
// Frames the Reader as "playback controls, seek bar hidden".
@Composable
fun ReaderCursorScene(layout: ScreenshotLayout, tag: String) {
    val copy = MarketingStrings.forScene("ReaderCursor", tag)
    ScreenshotFrame(title = copy.title, subtitle = copy.subtitle, layout = layout, subtitleBullet = copy.bullet) {
        FolinoTheme {
            val scene = rememberReaderSceneState {
                LayoutOptions.DEFAULT.copy(
                    mode = ReaderLayoutMode.VERTICAL,
                    staffSize = SCREENSHOT_STAFF_SIZE,
                )
            }
            // Live, prepared engine VM so the real PlaybackFab renders enabled (bound engine +
            // populated mixer). Null until the service binds and the score is prepared.
            val audioVm = rememberPreparedAudioVm(scene?.scoreHandle)
            Column(Modifier.fillMaxSize()) {
                // Real Reader top app bar (back + title + PiP/edit/playback/display actions). Static
                // screenshot: every callback is a no-op.
                ReaderTopBar(
                    onBack = {},
                    onShare = {},
                    onEditInfo = {},
                    onPlaybackControls = {},
                    onDisplaySettings = {},
                    windowInsets = WindowInsets(0, 0, 0, 0),
                )
                Box(Modifier.fillMaxSize().weight(1f)) {
                    if (scene != null) {
                        ReaderSceneContent(
                            state = scene.state,
                            scoreHandle = scene.scoreHandle,
                            layoutOptions = scene.layoutOptions,
                            withCursor = true,
                            // Defer the capture gate to also wait on the prepared engine below.
                            signalReadyWhenRendered = false,
                        )
                        if (audioVm != null) {
                            // Page rendered AND engine prepared: release the capture gate, then render
                            // the real transport cluster at the bottom-end (ReaderScreen's FAB slot).
                            LaunchedEffect(Unit) {
                                kotlinx.coroutines.delay(300)
                                SceneReady.signalReady()
                            }
                            Box(
                                Modifier
                                    .align(Alignment.BottomEnd)
                                    .padding(16.dp),
                            ) {
                                PlaybackFab(audioVm)
                            }
                        }
                    }
                }
            }
        }
    }
}
