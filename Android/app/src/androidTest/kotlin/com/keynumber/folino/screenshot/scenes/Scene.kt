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
    // `order` drives the output filename (NN.png) AND the Play Store display order, and the sequence is iOS's
    // (`ScreenshotScene`'s `id` prefixes) one for one, so the two listings tell the same story in the same
    // order: what the app shows, what you write into it, how it plays, how it looks, section practice, the
    // library, picture-in-picture.
    //
    // The names differ because each platform named its scene after what it stages rather than after the
    // feature: iOS's `playbackInspector` is this `LoopAll`, and its `visualInspector` is this `DisplayHidden`
    // (the same pairing `MarketingStrings` records against each entry).
    //
    // iOS has an eighth, `08_Annotation`, that Android has no scene for — annotation ships on both, so that is
    // a gap in this list rather than a difference between the apps.
    val all: List<Scene> = listOf(
        Scene("ReaderCursor", 10) { l, t -> ReaderCursorScene(l, t) },
        Scene("NoteEditing", 20) { l, t -> NoteEditingScene(l, t) },
        Scene("LoopAll", 30) { l, t -> LoopAllScene(l, t) },
        Scene("DisplayHidden", 40) { l, t -> DisplayHiddenScene(l, t) },
        Scene("AbRepeat", 50) { l, t -> AbRepeatScene(l, t) },
        Scene("Library", 60) { l, t -> LibraryScene(l, t) },
        Scene("Pip", 70) { l, t -> PipScene(l, t) },
    )
}
