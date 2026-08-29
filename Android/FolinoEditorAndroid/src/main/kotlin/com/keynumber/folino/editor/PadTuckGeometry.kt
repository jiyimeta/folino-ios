package com.keynumber.folino.editor

import com.keynumber.folino.editor.generated.EditorPadTuckBridgeViewModel

/** Which side edge the note pad is tucked off. Mirrors Swift's `EditorPadTuckSide`; [rawIndex] is the
 * discriminator that crosses the JNI boundary, for the reason every other enum crossing it is an integer. */
enum class PadTuckSide(val rawIndex: Int) {
    LEADING(0),
    TRAILING(1),
    ;

    companion object {
        fun fromRawIndex(rawIndex: Int): PadTuckSide = if (rawIndex == 0) LEADING else TRAILING
    }
}

/**
 * The thresholds and release decisions behind the note pad's PiP-style side tuck.
 *
 * **The answers are Swift's** — `EditorPadTuckGeometry` in `EditorCore`, which SwiftUI's own pad drag also calls,
 * so "how far is far enough" and "was that a dismissal or a reposition" cannot come out different on the two
 * platforms. This interface exists only so Compose has something to depend on that a JVM test can fake; the real
 * implementation is [SwiftPadTuckGeometry] below.
 *
 * Everything is in device pixels (`Float`, Compose's own unit), converted to `Double` at the boundary. The
 * geometry is scale-free — it takes a viewport, a card width and a translation and gives one back — so px is
 * simply the unit the gesture already speaks.
 *
 * Call it at the START and the END of a gesture, not per frame: the numbers between are a cached rest offset plus
 * the finger's translation, which is arithmetic rather than a decision, and a JNI hop per frame would put a
 * native call on the UI thread at the display's refresh rate for no answer it doesn't already have.
 */
interface PadTuckGeometry {
    /** How far a drag has to travel to change tuck state, in either direction. */
    fun threshold(viewportWidthPx: Float, viewportHeightPx: Float): Float

    /**
     * The tucked pad's resting horizontal offset from its centered position.
     *
     * [peekPx] is how much of the CARD deliberately stays on screen. Android passes a real sliver — the tucked pad
     * is its own grab point, the way this platform's PiP stashes a window — where iOS passes 0 and leaves a
     * separate pull tab.
     */
    fun restOffsetXPx(
        side: PadTuckSide,
        viewportWidthPx: Float,
        padWidthPx: Float,
        marginPx: Float,
        peekPx: Float,
    ): Float

    /** Where releasing an expanded pad's drag lands it, or `null` when the release was a reposition rather than a
     * dismissal. */
    fun tuckDestination(
        translationXPx: Float,
        projectedTranslationXPx: Float,
        velocityXPxPerSec: Float,
        velocityYPxPerSec: Float,
        thresholdPx: Float,
    ): PadTuckSide?

    /** Whether releasing a tucked pad's drag brings it back out. */
    fun restoresFromTuck(side: PadTuckSide, projectedTranslationXPx: Float, thresholdPx: Float): Boolean
}

/** [PadTuckGeometry] answered by the shared Swift implementation over JNI. */
class SwiftPadTuckGeometry(private val bridge: EditorPadTuckBridgeViewModel) : PadTuckGeometry {
    override fun threshold(viewportWidthPx: Float, viewportHeightPx: Float): Float =
        bridge.tuckThreshold(viewportWidthPx.toDouble(), viewportHeightPx.toDouble()).toFloat()

    override fun restOffsetXPx(
        side: PadTuckSide,
        viewportWidthPx: Float,
        padWidthPx: Float,
        marginPx: Float,
        peekPx: Float,
    ): Float = bridge.tuckRestOffsetX(
        side.rawIndex,
        viewportWidthPx.toDouble(),
        padWidthPx.toDouble(),
        marginPx.toDouble(),
        peekPx.toDouble(),
    ).toFloat()

    override fun tuckDestination(
        translationXPx: Float,
        projectedTranslationXPx: Float,
        velocityXPxPerSec: Float,
        velocityYPxPerSec: Float,
        thresholdPx: Float,
    ): PadTuckSide? {
        // -1 is the Swift side's "this was a reposition, not a dismissal" — a third state the two real sides'
        // own discriminators have no room for.
        val raw = bridge.tuckDestinationRawIndex(
            translationXPx.toDouble(),
            projectedTranslationXPx.toDouble(),
            velocityXPxPerSec.toDouble(),
            velocityYPxPerSec.toDouble(),
            thresholdPx.toDouble(),
        )
        return if (raw < 0) null else PadTuckSide.fromRawIndex(raw)
    }

    override fun restoresFromTuck(side: PadTuckSide, projectedTranslationXPx: Float, thresholdPx: Float): Boolean =
        bridge.restoresFromTuck(side.rawIndex, projectedTranslationXPx.toDouble(), thresholdPx.toDouble())
}
