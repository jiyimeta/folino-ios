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
    // Reader+cursor, note editing, display-hidden, whole-piece-repeat, AB-repeat, Library, PiP.
    //
    // Note editing sits second, where iOS puts it (`02_NoteEditing`): after the shot that establishes what the
    // app shows, before the ones that adjust how it is shown or played. It is also the newest thing the app
    // does, and a listing's second image is the last one most people scroll to.
    val all: List<Scene> = listOf(
        Scene("ReaderCursor", 10) { l, t -> ReaderCursorScene(l, t) },
        Scene("NoteEditing", 20) { l, t -> NoteEditingScene(l, t) },
        Scene("DisplayHidden", 30) { l, t -> DisplayHiddenScene(l, t) },
        Scene("LoopAll", 40) { l, t -> LoopAllScene(l, t) },
        Scene("AbRepeat", 50) { l, t -> AbRepeatScene(l, t) },
        Scene("Library", 60) { l, t -> LibraryScene(l, t) },
        Scene("Pip", 70) { l, t -> PipScene(l, t) },
    )
}
