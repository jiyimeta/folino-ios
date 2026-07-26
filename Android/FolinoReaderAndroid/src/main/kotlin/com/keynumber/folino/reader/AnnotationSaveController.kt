package com.keynumber.folino.reader

import android.content.Context
import androidx.lifecycle.ViewModel
import androidx.lifecycle.ViewModelProvider
import com.keynumber.folino.reader.generated.AnnotationSaveBridgeViewModel

/**
 * Thin factory around the generated [AnnotationSaveBridgeViewModel], the wirelet-observable view model that wraps the
 * Swift `AnnotationSaveBridge`. Mirrors `ReaderPreferencesController`: the generated view model already extends
 * [ViewModel] and is directly usable — it exposes the write-path passthroughs Sub-plan E's ink overlay calls:
 *
 * - `open(scoreId)` — mark the active score and prime the coordinator's load path.
 * - `drawingsChanged(wires)` — push the current layer's `List<DrawingAnchorWire>` (built from androidx.ink strokes in
 *   Sub-plan E) and (re)arm the shared debounce.
 * - `flush()` — force an immediate write, bypassing the debounce (score-swap / teardown; e.g. from `onPause`).
 *
 * Persistence is the Room-backed [RoomAnnotationStore]; its underlying [AnnotationDatabase] is a shared singleton, so
 * constructing a new `RoomAnnotationStore` per view model is cheap and shares one database. The native bridge is
 * released via the generated view model's `onCleared`.
 */
object AnnotationSaveController {

    /** Builds a view model backed by a [RoomAnnotationStore] for the given context. */
    fun build(context: Context): AnnotationSaveBridgeViewModel =
        AnnotationSaveBridgeViewModel.create(RoomAnnotationStore(context.applicationContext))

    /**
     * Builds a view model injected with an explicit [AnnotationPersistenceStore]. Useful for tests / fakes; production
     * callers pass a [RoomAnnotationStore].
     */
    fun build(store: AnnotationPersistenceStore): AnnotationSaveBridgeViewModel =
        AnnotationSaveBridgeViewModel.create(store)

    /**
     * A [ViewModelProvider.Factory] that scopes the bridge view model to a Reader screen's lifecycle (mirrors the app's
     * `LibraryVMFactory` / `ReaderPreferencesController`). The Room database is released via the view model's
     * `onCleared`.
     */
    fun factory(context: Context): ViewModelProvider.Factory =
        object : ViewModelProvider.Factory {
            @Suppress("UNCHECKED_CAST")
            override fun <T : ViewModel> create(modelClass: Class<T>): T =
                build(context) as T
        }
}
