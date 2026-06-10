package com.keynumber.folino.reader

import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

/**
 * Holds repeat state and mirrors iOS `RepeatModel` behavior. Engine/persistence-agnostic: callers
 * inject the current-measure source, persistence, and the loop-applier so the controller is a pure,
 * unit-testable state machine.
 *
 * - [setA]/[setB] snap to the current playback measure; re-tapping an endpoint's own measure clears
 *   it (iOS toggle behavior).
 * - The A–B range is committed (and persisted) only when both endpoints exist; it is normalized so
 *   start <= end ([AbRepeatRange.normalized]).
 * - [setMode] persists the global mode and re-applies the active loop.
 *
 * @param currentMeasureProvider current playback measure index (or null when unknown).
 * @param persistedRangeLoader the per-score range restored at construction (or null).
 * @param persistRange writes the committed range (null clears it) — per-score persistence.
 * @param persistMode writes the global sticky mode.
 * @param applyLoop receives `(range, mode)`. For LOOP_ALL `range` is null and the applier loops the
 *   whole score; for AB_LOOP a non-null `range` loops those measures and null clears; for OFF it
 *   clears.
 */
class ReaderRepeatController(
    private val currentMeasureProvider: () -> Int?,
    private val persistedRangeLoader: () -> AbRepeatRange?,
    private val persistRange: (AbRepeatRange?) -> Unit,
    private val persistMode: (RepeatMode) -> Unit,
    private val applyLoop: (AbRepeatRange?, RepeatMode) -> Unit,
    initialMode: RepeatMode,
) {
    private val _mode = MutableStateFlow(initialMode)
    val mode: StateFlow<RepeatMode> = _mode.asStateFlow()

    private val _abRange = MutableStateFlow(persistedRangeLoader())
    val abRange: StateFlow<AbRepeatRange?> = _abRange.asStateFlow()

    private val _pendingA = MutableStateFlow(_abRange.value?.startMeasure)
    /** Staged A endpoint measure (or null). Drives the A button's set/unset state. */
    val pendingA: StateFlow<Int?> = _pendingA.asStateFlow()

    private val _pendingB = MutableStateFlow(_abRange.value?.endMeasure)
    /** Staged B endpoint measure (or null). Drives the B button's set/unset state. */
    val pendingB: StateFlow<Int?> = _pendingB.asStateFlow()

    fun setA() {
        val m = currentMeasureProvider() ?: return
        _pendingA.value = if (_pendingA.value == m) null else m // re-tap same measure clears
        commit()
    }

    fun setB() {
        val m = currentMeasureProvider() ?: return
        _pendingB.value = if (_pendingB.value == m) null else m
        commit()
    }

    fun setMode(mode: RepeatMode) {
        if (_mode.value == mode) return
        _mode.value = mode
        persistMode(mode)
        applyActiveLoop()
    }

    /** Re-apply the active loop (e.g. after the score finishes preparing). */
    fun reapply() = applyActiveLoop()

    private fun commit() {
        val a = _pendingA.value
        val b = _pendingB.value
        val range = if (a != null && b != null) AbRepeatRange(a, b).normalized() else null
        if (range != null) {
            _pendingA.value = range.startMeasure
            _pendingB.value = range.endMeasure
        }
        _abRange.value = range
        persistRange(range)
        applyActiveLoop()
    }

    private fun applyActiveLoop() {
        when (_mode.value) {
            RepeatMode.OFF -> applyLoop(null, RepeatMode.OFF)
            RepeatMode.LOOP_ALL -> applyLoop(null, RepeatMode.LOOP_ALL)
            RepeatMode.AB_LOOP -> applyLoop(_abRange.value, RepeatMode.AB_LOOP)
        }
    }
}
