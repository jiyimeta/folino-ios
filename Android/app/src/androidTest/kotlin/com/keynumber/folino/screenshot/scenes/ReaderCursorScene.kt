package com.keynumber.folino.screenshot.scenes

import androidx.compose.runtime.Composable
import com.keynumber.folino.reader.LayoutOptions
import com.keynumber.folino.screenshot.fixtures.MarketingStrings
import com.keynumber.folino.screenshot.fixtures.ReaderSceneHost
import com.keynumber.folino.screenshot.frame.ScreenshotFrame
import com.keynumber.folino.screenshot.frame.ScreenshotLayout
import com.keynumber.folino.ui.theme.FolinoTheme

// Reader scene: the real bundled score laid out by ReaderViewModel, with a static playback cursor
// placed near the middle of the first measure (pure JNI hit-test, no audio engine).
@Composable
fun ReaderCursorScene(layout: ScreenshotLayout, tag: String) {
    val copy = MarketingStrings.forScene("ReaderCursor", tag)
    ScreenshotFrame(title = copy.title, subtitle = copy.subtitle, layout = layout) {
        FolinoTheme {
            ReaderSceneHost(layoutOptions = LayoutOptions.DEFAULT, withCursor = true)
        }
    }
}
