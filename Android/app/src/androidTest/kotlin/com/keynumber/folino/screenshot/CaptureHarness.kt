package com.keynumber.folino.screenshot

import android.graphics.Bitmap
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.size
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.asAndroidBitmap
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.test.captureToImage
import androidx.compose.ui.test.junit4.ComposeContentTestRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.unit.Density
import androidx.compose.ui.unit.dp
import androidx.test.services.storage.TestStorage
import com.keynumber.folino.screenshot.fixtures.SceneReady
import java.io.BufferedOutputStream

// Tag on the fixed-size capture Box so we can target exactly that node (not the whole window, which
// would include any decor) for the bitmap capture.
private const val CAPTURE_TAG = "screenshot-capture-root"

// Renders `content` inside a Box sized to exactly (widthPx × heightPx) device pixels by forcing a
// density of 1.0 for the wrapper (so 1.dp == 1px at this level; the frame's own inner density
// override still scales the app subtree), then captures that node to a PNG.
//
// CONNECTED-MODE OUTPUT (why not Roborazzi's captureRoboImage):
// Roborazzi's connected/instrumented file-write path resolves a *relative* filePath against the
// device process CWD ("/"), which is unwritable, so the bitmap silently never lands; and its
// recording is gated behind a device-side system property that `connectedDebugAndroidTest` does not
// set. Rather than fight that plumbing, we capture the node to an in-memory Bitmap via Compose's
// `captureToImage()` and write the PNG through AndroidX `TestStorage.openOutputFile(name)`. With
// `useTestStorageService=true` (see app/build.gradle.kts defaultConfig), AGP pulls the whole
// TestStorage output tree to the host under
//   app/build/outputs/connected_android_test_additional_output/debugAndroidTest/connected/<Device>/
// preserving the relative `name` we pass here (e.g. "phone/en-US/30.png"). `collectScreenshots`
// then walks that tree into the fastlane supply layout.
fun ComposeContentTestRule.captureFixedSize(
    widthPx: Int,
    heightPx: Int,
    filePath: String,
    content: @Composable () -> Unit,
) {
    SceneReady.reset()
    setContent {
        CompositionLocalProvider(LocalDensity provides Density(density = 1f, fontScale = 1f)) {
            Box(modifier = Modifier.size(widthPx.dp, heightPx.dp).testTag(CAPTURE_TAG)) {
                content()
            }
        }
    }
    waitForIdle()
    // Async-content scenes (e.g. the Reader) parse + lay out a score on background dispatchers that
    // `waitForIdle()` does not track. Such a scene calls SceneReady.markGated() during composition and
    // signalReady() once rendered; block on that here (bounded) so the bitmap captures the real score.
    if (SceneReady.isGated()) {
        waitUntil(timeoutMillis = 20_000) { SceneReady.isReady() }
        waitForIdle()
    }
    val bitmap = onNodeWithTag(CAPTURE_TAG).captureToImage().asAndroidBitmap()
    TestStorage().openOutputFile(filePath).use { raw ->
        BufferedOutputStream(raw).use { out ->
            bitmap.compress(Bitmap.CompressFormat.PNG, 100, out)
        }
    }
}
