package com.keynumber.folino.screenshot.scenes

import androidx.compose.runtime.Composable
import com.keynumber.folino.screenshot.frame.ScreenshotLayout

// One marketing scene. `order` drives the output filename. `content` renders the framed
// scene for the given device layout and language tag.
class Scene(
    val id: String,
    val order: Int,
    val content: @Composable (layout: ScreenshotLayout, tag: String) -> Unit,
) {
    // Drives the Parameterized test display name (e.g. "PHONE-EN-Library").
    override fun toString(): String = id
}

object Scenes {
    // `order` drives the output filename (NN.png) AND the Play Store display order:
    // Reader+cursor, display-hidden, whole-piece-repeat, AB-repeat, Library, PiP.
    val all: List<Scene> = listOf(
        Scene("ReaderCursor", 10) { l, t -> ReaderCursorScene(l, t) },
        Scene("DisplayHidden", 20) { l, t -> DisplayHiddenScene(l, t) },
        Scene("LoopAll", 30) { l, t -> LoopAllScene(l, t) },
        Scene("AbRepeat", 40) { l, t -> AbRepeatScene(l, t) },
        Scene("Library", 50) { l, t -> LibraryScene(l, t) },
        Scene("Pip", 60) { l, t -> PipScene(l, t) },
    )
}
