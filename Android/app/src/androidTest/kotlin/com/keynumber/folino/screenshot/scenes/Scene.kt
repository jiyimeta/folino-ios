package com.keynumber.folino.screenshot.scenes

import androidx.compose.runtime.Composable
import com.keynumber.folino.screenshot.frame.ScreenshotLayout

// One marketing scene. `order` drives the output filename. `content` renders the framed
// scene for the given device layout and language tag.
class Scene(
    val id: String,
    val order: Int,
    val content: @Composable (layout: ScreenshotLayout, tag: String) -> Unit,
)

object Scenes {
    // Populated as scenes are added (Tasks 5-8). Orders reserve 40/50 for deferred repeat scenes.
    val all: List<Scene> = listOf(
        // Scene("ReaderCursor", 10) { l, t -> ReaderCursorScene(l, t) },   // Task 6
        // Scene("DisplayHidden", 20) { l, t -> DisplayHiddenScene(l, t) }, // Task 7
        // Scene("Library", 30) { l, t -> LibraryScene(l, t) },            // Task 5
        // Scene("Pip", 60) { l, t -> PipScene(l, t) },                    // Task 8
    )
}
