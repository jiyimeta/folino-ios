package com.keynumber.folino.screenshot.scenes

import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material3.FloatingActionButton
import androidx.compose.material3.FloatingActionButtonDefaults
import androidx.compose.material3.Icon
import androidx.compose.material3.contentColorFor
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import com.keynumber.folino.reader.LayoutOptions
import com.keynumber.folino.screenshot.fixtures.MarketingStrings
import com.keynumber.folino.screenshot.fixtures.ReaderSceneHost
import com.keynumber.folino.screenshot.fixtures.SCREENSHOT_STAFF_SIZE
import com.keynumber.folino.screenshot.frame.ScreenshotFrame
import com.keynumber.folino.screenshot.frame.ScreenshotLayout
import com.keynumber.folino.ui.theme.FolinoTheme

// Reader scene: the real bundled score laid out by ReaderViewModel, with a static playback cursor
// placed near the middle of the first measure (pure JNI hit-test, no audio engine). On top, the
// seek-bar-OFF transport affordance — the floating play FAB — frames it as "the Reader with playback
// controls, seek bar hidden".
@Composable
fun ReaderCursorScene(layout: ScreenshotLayout, tag: String) {
    val copy = MarketingStrings.forScene("ReaderCursor", tag)
    ScreenshotFrame(title = copy.title, subtitle = copy.subtitle, layout = layout) {
        FolinoTheme {
            Box(Modifier.fillMaxSize()) {
                ReaderSceneHost(
                    layoutOptions = LayoutOptions.DEFAULT.copy(staffSize = SCREENSHOT_STAFF_SIZE),
                    withCursor = true,
                )
                ReaderPlayFab(
                    Modifier
                        .align(Alignment.BottomEnd)
                        .padding(16.dp),
                )
            }
        }
    }
}

// Static replica of ReaderScreen's seek-bar-OFF `PlaybackFab` main button. The production FAB is a
// `FloatingActionButton` (PlayArrow icon) at `FabPosition.End`, driven by a `ReaderAudioViewModel`
// the screenshot harness has no engine for — so we replicate its appearance (same icon, prepared-state
// container/content colors, bottom-end placement) rather than reusing the engine-bound composable.
@Composable
private fun ReaderPlayFab(modifier: Modifier = Modifier) {
    FloatingActionButton(
        onClick = {},
        modifier = modifier,
        containerColor = FloatingActionButtonDefaults.containerColor,
        contentColor = contentColorFor(FloatingActionButtonDefaults.containerColor),
    ) {
        Icon(Icons.Default.PlayArrow, contentDescription = "Play")
    }
}
