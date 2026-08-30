package com.keynumber.folino.reader.hints

import android.content.Context
import androidx.annotation.StringRes
import com.keynumber.folino.reader.R
import com.keynumber.folino.reader.ReaderHintBubbleFrameWireCodec
import com.keynumber.folino.reader.ReaderHintBubbleMetricsWire
import com.keynumber.folino.reader.ReaderHintBubbleMetricsWireCodec
import com.keynumber.folino.reader.ReaderHintStateWireCodec
import com.keynumber.folino.reader.swiftjava.FolinoReaderJNI
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import org.swift.swiftkit.core.SwiftMemoryManagement
import java.io.File

/**
 * The Reader's coach marks — the Android half of a feature whose decisions all live in Swift.
 *
 * `ReaderInteractionCore.ReaderHintEngine` owns which hint is due, the one-per-launch budget, the round-robin that
 * skips a hint whose control is off screen, the offers that ride a control's appearance, and permanent retirement on
 * first real use. iOS's `ReaderHintCoordinator` wraps that same engine. Nothing in this file decides any of it: it
 * reports anchors, runs the delays the engine asks for, draws the bubble and performs the action a tapped bubble
 * describes.
 *
 * That split is the point. A Kotlin reimplementation of the sequencing would be a second feature that merely
 * resembled iOS's, and the difference would only ever show up as "the hint I dismissed came back on my phone".
 */
enum class ReaderFeatureHint(
    val wire: Int,
    @StringRes val titleRes: Int,
    @StringRes private val messageRes: Int,
    /** Only the annotation hint differs by form factor; every other hint ignores this. */
    @StringRes private val tabletMessageRes: Int = 0,
) {
    TRANSPORT_COLLAPSE(
        0,
        R.string.reader_hint_transport_collapse_title,
        R.string.reader_hint_transport_collapse_message,
    ),
    TRANSPORT_EXPAND(
        1,
        R.string.reader_hint_transport_expand_title,
        R.string.reader_hint_transport_expand_message,
    ),
    NOTE_EDITING(2, R.string.reader_hint_note_editing_title, R.string.reader_hint_note_editing_message),
    ANNOTATION(
        3,
        R.string.reader_hint_annotation_title,
        R.string.reader_hint_annotation_message_phone,
        R.string.reader_hint_annotation_message_tablet,
    ),
    STAFF_VISIBILITY(
        4,
        R.string.reader_hint_staff_visibility_title,
        R.string.reader_hint_staff_visibility_message,
    ),
    METRONOME(5, R.string.reader_hint_metronome_title, R.string.reader_hint_metronome_message),
    REPEAT_PLAYBACK(
        6,
        R.string.reader_hint_repeat_playback_title,
        R.string.reader_hint_repeat_playback_message,
    ),
    MIXER(7, R.string.reader_hint_mixer_title, R.string.reader_hint_mixer_message),

    // PARITY(android): note-input pad coach marks — the engine already sequences padHide / padRestore / padMove
    //   (they are cases of `ReaderInteractionCore.ReaderFeatureHint` and covered by ReaderHintEngineTests), but
    //   Android never reports the `noteInputPad` / `noteInputPadHandle` anchors, so they are never offered. Report
    //   those two frames from the Compose editing chrome and add the six strings; no engine change is needed —
    //   a hint whose control has no anchor is skipped by the same rule that skips the note-editing hint on a PDF.
    PAD_HIDE(8, 0, 0),
    PAD_RESTORE(9, 0, 0),
    PAD_MOVE(10, 0, 0),
    ;

    /** Whether this hint has Android copy yet — see the PARITY note above. */
    val isPresentable: Boolean get() = titleRes != 0

    @StringRes
    fun messageRes(isTablet: Boolean): Int =
        if (isTablet && tabletMessageRes != 0) tabletMessageRes else messageRes

    companion object {
        const val NONE_WIRE = -1

        fun fromWire(wire: Int): ReaderFeatureHint? = entries.firstOrNull { it.wire == wire }
    }
}

/** A control a hint can point at. Numbering mirrors `ReaderInteractionCore.ReaderHintTarget.wireValue`. */
enum class ReaderHintTarget(val wire: Int) {
    TRANSPORT_EXPANDED(0),
    TRANSPORT_COMPACT(1),
    NOTE_EDITING_BUTTON(2),
    ANNOTATION_BUTTON(3),
    VISUAL_INSPECTOR_BUTTON(4),
    PLAYBACK_INSPECTOR_BUTTON(5),
    NOTE_INPUT_PAD(6),
    NOTE_INPUT_PAD_HANDLE(7),
}

/** An anchor rect in window coordinates, in dp — the unit the shared layout math is stated in. */
data class ReaderHintAnchor(val x: Double, val y: Double, val width: Double, val height: Double)

/** Where the bubble goes, straight out of `ReaderHintBubbleLayout.frame`. */
data class ReaderHintBubbleFrame(
    val width: Double,
    val originX: Double,
    val caretDX: Double,
    /** True when the card hangs below its control (caret up). */
    val below: Boolean,
    val edgeY: Double,
)

/** The engine's slot, as last read. */
data class ReaderHintState(
    val hint: ReaderFeatureHint?,
    val anchor: ReaderHintAnchor?,
    val transportModeSwitchRequests: Int,
    val transportExpandSchedule: Int,
    val padRestoreSchedule: Int,
    val padMoveSchedule: Int,
    val deferredOfferDelayMillis: Long,
) {
    companion object {
        val EMPTY = ReaderHintState(null, null, 0, 0, 0, 0, 600)
    }
}

/** The three offers that ride a control's appearance. Numbering mirrors `nativeHintFireDeferredOffer`. */
enum class ReaderHintDeferredOffer(val wire: Int) {
    TRANSPORT_EXPAND(0),
    PAD_RESTORE(1),
    PAD_MOVE(2),
}

/**
 * The process-wide handle on the Swift engine.
 *
 * A singleton because the engine is one: the "at most one hint per launch" budget has to hold across every score
 * opened in this launch. Main thread only — every entry point is reached from a composable, an effect or a gesture
 * callback, which is the same contract iOS states with `@MainActor`.
 *
 * Every state change is initiated from here (an anchor report, a use, an offer, a fired timer), so re-reading the
 * whole slot after each call is enough to stay in step — nothing changes behind Compose's back, which is why this
 * needs no observable bridge.
 */
object ReaderHintController {
    private val _state = MutableStateFlow(ReaderHintState.EMPTY)
    val state: StateFlow<ReaderHintState> = _state.asStateFlow()

    private var configured = false

    /** The card's own measurements, read once — they are compile-time constants on the Swift side. */
    val metrics: ReaderHintBubbleMetricsWire by lazy {
        ReaderHintBubbleMetricsWireCodec.decode(
            FolinoReaderJNI.nativeHintBubbleMetrics(SwiftMemoryManagement.DEFAULT_SWIFT_JAVA_AUTO_ARENA)
                .toByteArray(),
        )
    }

    /**
     * Names the store the engine keeps its "already used" flags and rotation cursor in. Idempotent, so it is safe to
     * call from wherever the Reader is entered.
     */
    fun configure(context: Context) {
        if (configured) return
        configured = true
        val file = File(context.applicationContext.filesDir, "reader-hints.json")
        FolinoReaderJNI.nativeHintConfigure(file.absolutePath)
        refresh()
    }

    fun setAnchor(target: ReaderHintTarget, anchor: ReaderHintAnchor) {
        FolinoReaderJNI.nativeHintSetAnchor(
            target.wire, anchor.x, anchor.y, anchor.width, anchor.height,
        )
        refresh()
    }

    fun clearAnchor(target: ReaderHintTarget) {
        FolinoReaderJNI.nativeHintClearAnchor(target.wire)
        refresh()
    }

    fun clearAllAnchors() {
        FolinoReaderJNI.nativeHintClearAllAnchors()
        refresh()
    }

    fun setEditing(editing: Boolean) {
        FolinoReaderJNI.nativeHintSetEditing(editing)
        refresh()
    }

    /** The user actually used the feature — the hint retires for good. */
    fun markUsed(hint: ReaderFeatureHint) {
        FolinoReaderJNI.nativeHintMarkUsed(hint.wire)
        refresh()
    }

    fun offerRotationHint() {
        FolinoReaderJNI.nativeHintOfferRotation()
        refresh()
    }

    fun dismiss() {
        FolinoReaderJNI.nativeHintDismiss()
        refresh()
    }

    /** The bubble was tapped and it teaches a transport swipe: ask the transport to act that swipe out. */
    fun requestTransportModeSwitch() {
        FolinoReaderJNI.nativeHintRequestTransportModeSwitch()
        refresh()
    }

    /** The delay the engine asked for has elapsed. It re-checks its own preconditions, so this is never unsafe. */
    fun fireDeferredOffer(offer: ReaderHintDeferredOffer) {
        FolinoReaderJNI.nativeHintFireDeferredOffer(offer.wire)
        refresh()
    }

    /** QA reset, wired to the debug menu the way iOS's `ReaderHints.resetAll()` is. */
    fun resetAll() {
        FolinoReaderJNI.nativeHintReset()
        refresh()
    }

    fun bubbleFrame(
        target: ReaderHintTarget,
        anchor: ReaderHintAnchor,
        viewportWidth: Double,
        viewportHeight: Double,
    ): ReaderHintBubbleFrame {
        val wire = ReaderHintBubbleFrameWireCodec.decode(
            FolinoReaderJNI.nativeHintBubbleFrame(
                target.wire,
                anchor.x, anchor.y, anchor.width, anchor.height,
                viewportWidth, viewportHeight,
                SwiftMemoryManagement.DEFAULT_SWIFT_JAVA_AUTO_ARENA,
            ).toByteArray(),
        )
        return ReaderHintBubbleFrame(
            width = wire.width,
            originX = wire.originX,
            caretDX = wire.caretDX,
            below = wire.placement == 1,
            edgeY = wire.edgeY,
        )
    }

    private fun refresh() {
        val wire = ReaderHintStateWireCodec.decode(
            FolinoReaderJNI.nativeHintState(SwiftMemoryManagement.DEFAULT_SWIFT_JAVA_AUTO_ARENA).toByteArray(),
        )
        val hint = ReaderFeatureHint.fromWire(wire.presentedHint)?.takeIf { it.isPresentable }
        _state.value = ReaderHintState(
            hint = hint,
            anchor = if (wire.hasAnchor) {
                ReaderHintAnchor(wire.anchorX, wire.anchorY, wire.anchorWidth, wire.anchorHeight)
            } else {
                null
            },
            transportModeSwitchRequests = wire.transportModeSwitchRequests,
            transportExpandSchedule = wire.transportExpandSchedule,
            padRestoreSchedule = wire.padRestoreSchedule,
            padMoveSchedule = wire.padMoveSchedule,
            deferredOfferDelayMillis = wire.deferredOfferDelayMillis.toLong(),
        )
    }
}

/** The control each hint points at — the Kotlin mirror of `ReaderFeatureHint.target`. */
val ReaderFeatureHint.target: ReaderHintTarget
    get() = when (this) {
        ReaderFeatureHint.TRANSPORT_COLLAPSE -> ReaderHintTarget.TRANSPORT_EXPANDED
        ReaderFeatureHint.TRANSPORT_EXPAND -> ReaderHintTarget.TRANSPORT_COMPACT
        ReaderFeatureHint.NOTE_EDITING -> ReaderHintTarget.NOTE_EDITING_BUTTON
        ReaderFeatureHint.ANNOTATION -> ReaderHintTarget.ANNOTATION_BUTTON
        ReaderFeatureHint.STAFF_VISIBILITY -> ReaderHintTarget.VISUAL_INSPECTOR_BUTTON
        ReaderFeatureHint.METRONOME,
        ReaderFeatureHint.REPEAT_PLAYBACK,
        ReaderFeatureHint.MIXER,
        -> ReaderHintTarget.PLAYBACK_INSPECTOR_BUTTON
        ReaderFeatureHint.PAD_HIDE, ReaderFeatureHint.PAD_MOVE -> ReaderHintTarget.NOTE_INPUT_PAD
        ReaderFeatureHint.PAD_RESTORE -> ReaderHintTarget.NOTE_INPUT_PAD_HANDLE
    }
