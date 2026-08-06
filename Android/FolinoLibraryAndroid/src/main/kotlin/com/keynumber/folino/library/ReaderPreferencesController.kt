package com.keynumber.folino.library

import android.content.Context
import androidx.lifecycle.ViewModel
import androidx.lifecycle.ViewModelProvider
import com.keynumber.folino.library.generated.ReaderPreferencesBridgeViewModel

/**
 * Thin factory around the generated [ReaderPreferencesBridgeViewModel], the wirelet-observable view model that
 * wraps the Swift `ReaderPreferencesBridge`. Mirrors `SoundfontController` (and `LibraryVMFactory`): the generated
 * view model is already directly Compose-usable — it extends [ViewModel], exposes the observable `state` as a
 * `StateFlow<ReaderPreferencesStateWire>` (`collectAsState()`-able), and provides the scalar / per-staff mutators
 * and list getters as plain pass-through methods — so this is just construction + store injection, not a wrapper.
 *
 * Unlike the process-wide soundfont download bridge, Reader preferences are per-score: callers obtain a fresh view
 * model per Reader screen (scoped via [factory] + `ViewModelProvider`, or built ad-hoc with [build]) and call
 * `open(scoreId, defaultStaffSize, defaultHonorLayoutBreaks)` to load that score's stored JSON blob. The
 * persistence is the same Room-backed [RoomLibraryStore] used elsewhere; its underlying `LibraryDatabase` is a
 * shared singleton, so constructing a new `RoomLibraryStore` per view model is cheap and shares one database.
 */
object ReaderPreferencesController {

    /** Builds a view model backed by a [RoomLibraryStore] for the given context. */
    fun build(context: Context): ReaderPreferencesBridgeViewModel =
        ReaderPreferencesBridgeViewModel.create(RoomLibraryStore(context.applicationContext))

    /**
     * Builds a view model injected with an explicit [ReaderPreferencesStore]. Useful for tests / fakes; production
     * callers pass a [RoomLibraryStore] (which implements [ReaderPreferencesStore]).
     */
    fun build(store: ReaderPreferencesStore): ReaderPreferencesBridgeViewModel =
        ReaderPreferencesBridgeViewModel.create(store)

    /**
     * A [ViewModelProvider.Factory] that scopes the bridge view model to a Reader screen's lifecycle (mirrors the
     * app's `LibraryVMFactory`). The Room database is released via the generated view model's `onCleared`.
     */
    fun factory(context: Context): ViewModelProvider.Factory =
        object : ViewModelProvider.Factory {
            @Suppress("UNCHECKED_CAST")
            override fun <T : ViewModel> create(modelClass: Class<T>): T =
                build(context) as T
        }
}
