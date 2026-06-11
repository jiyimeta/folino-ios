package com.keynumber.folino.screenshot.scenes

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.clipToBounds
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.layout.onSizeChanged
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.keynumber.folino.reader.LayoutOptions
import com.keynumber.folino.reader.ReaderLayoutMode
import com.keynumber.folino.reader.nearestCursorForTap
import com.keynumber.folino.screenshot.fixtures.LocalReaderSeedLayoutWidthMm
import com.keynumber.folino.screenshot.fixtures.MarketingStrings
import com.keynumber.folino.screenshot.fixtures.SCREENSHOT_STAFF_SIZE
import com.keynumber.folino.screenshot.fixtures.SceneReady
import com.keynumber.folino.screenshot.fixtures.rememberReaderSceneState
import com.keynumber.folino.screenshot.frame.ScreenshotFrame
import com.keynumber.folino.screenshot.frame.ScreenshotLayout
import com.keynumber.folino.ui.theme.FolinoTheme
import io.github.jiyimeta.sheetmusic.audio.model.ScoreCursor
import io.github.jiyimeta.sheetmusic.compose.cursor.PlaybackCursorOverlay
import io.github.jiyimeta.sheetmusic.compose.render.ScorePage
import io.github.jiyimeta.sheetmusic.compose.render.bundledFontProvider
import kotlinx.coroutines.flow.MutableStateFlow

// PiP scene: mirrors Folino's real picture-in-picture window — a WIDE card pinned near the TOP of the
// home screen showing the score in HORIZONTAL layout (one continuous single-system row) with only staves
// 2/3/4 = Top/2nd/3rd visible. The card hides every staff EXCEPT flattened indices 1,2,3 (the complement
// of the display-inspector scene's hidden set), so the three kept staves form a short wide strip. The home
// backdrop is intentionally plain (no wallpaper art / widgets) — just a dark launcher with app icons and a
// shape-only search bar, enough to read as "playing over the home screen".
@Composable
fun PipScene(layout: ScreenshotLayout, tag: String) {
    val copy = MarketingStrings.forScene("Pip", tag)
    ScreenshotFrame(title = copy.title, subtitle = copy.subtitle, layout = layout) {
        FolinoTheme {
            Box(Modifier.fillMaxSize()) {
                FauxHomeScreen()
                // Real Folino PiP sits as a wide, short window just below the status bar. PiP is
                // intentionally fit-to-A4-width (a small fixed card), so seed the score layout at A4
                // width — NOT this device's reflow width — to keep the PiP window unchanged.
                CompositionLocalProvider(LocalReaderSeedLayoutWidthMm provides A4_WIDTH_MM) {
                    PipCard(Modifier.align(Alignment.TopCenter).padding(top = 40.dp, start = 10.dp, end = 10.dp))
                }
            }
        }
    }
}

// Plain dark launcher backdrop: a status bar, two rows of circular app icons in the lower half, and a
// shape-only search pill at the bottom. No wallpaper image and no widgets (kept deliberately simple).
@Composable
private fun FauxHomeScreen() {
    Box(Modifier.fillMaxSize().background(Color(0xFF101013))) {
        Column(Modifier.fillMaxSize().padding(horizontal = 22.dp)) {
            FauxStatusBar()
            // Empty upper half — the PiP card floats here.
            Spacer(Modifier.weight(1f))
            val tints = listOf(
                Color(0xFF5C8DEF), Color(0xFFE7574A), Color(0xFF34A853), Color(0xFFFF5252),
                Color(0xFF4285F4), Color(0xFF42A5F5), Color(0xFF26A69A), Color(0xFFFFB300),
            )
            AppIconRow(0..3, tints)
            Spacer(Modifier.height(24.dp))
            AppIconRow(4..7, tints)
            Spacer(Modifier.height(30.dp))
            SearchPill()
            Spacer(Modifier.height(18.dp))
        }
    }
}

@Composable
private fun AppIconRow(range: IntRange, tints: List<Color>) {
    Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
        for (i in range) {
            Box(Modifier.size(56.dp).clip(CircleShape).background(tints[i]))
        }
    }
}

// Faux status bar: clock on the left, a couple of indicator shapes on the right.
@Composable
private fun FauxStatusBar() {
    Row(
        Modifier.fillMaxWidth().padding(top = 8.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text("9:41", color = Color.White, fontSize = 13.sp, fontWeight = FontWeight.Medium)
        Spacer(Modifier.weight(1f))
        // Wi-Fi + battery placeholders (shapes only).
        Box(Modifier.size(13.dp).clip(CircleShape).background(Color.White.copy(alpha = 0.85f)))
        Spacer(Modifier.width(6.dp))
        Box(Modifier.width(22.dp).height(12.dp).clip(RoundedCornerShape(3.dp)).background(Color.White.copy(alpha = 0.85f)))
    }
}

// Shape-only Google-style search pill at the bottom of the launcher.
@Composable
private fun SearchPill() {
    Row(
        Modifier
            .fillMaxWidth()
            .height(50.dp)
            .clip(RoundedCornerShape(25.dp))
            .background(Color.White.copy(alpha = 0.12f))
            .padding(horizontal = 18.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Box(Modifier.size(20.dp).clip(CircleShape).background(Color.White.copy(alpha = 0.55f)))
        Spacer(Modifier.weight(1f))
        Box(Modifier.size(16.dp).clip(CircleShape).background(Color.White.copy(alpha = 0.35f)))
        Spacer(Modifier.width(14.dp))
        Box(Modifier.size(16.dp).clip(CircleShape).background(Color.White.copy(alpha = 0.35f)))
    }
}

// A4-width basis for the horizontal pxPerMM, mirroring HorizontalScore (which fits the card/viewport width
// to A4 width, NOT to the page's natural — very wide — single-row width, then scrolls horizontally).
private const val A4_WIDTH_MM = 210.0

// Horizontal distance (document mm) to scroll past the intro/clef/key signature at the row's left so the
// visible window lands on a stretch with notes rather than the staff header.
private const val PIP_SCROLL_LEFT_MM = 26.0

// Vertical air (document mm) above and below the three-staff strip inside the card, so the staves aren't
// flush against the rounded card edges.
private const val PIP_VPAD_MM = 3.0

// The floating PiP window: a wide, short, rounded white surface holding the score's three kept staves
// (flattened indices 1,2,3) as ONE continuous HORIZONTAL row — matching Folino's real PiP, which forces
// horizontal single-system layout and is full-width and a few staves tall.
//
// In HORIZONTAL the program is one wide single-system row. Like the production HorizontalScore, we fit the
// card WIDTH to A4 width (not the row's natural width) for the px-per-mm, render the wide page, scroll it
// horizontally past the staff header, and size the card height to exactly the three-staff strip (so the
// staves fill the card tightly with a little vertical air, the way the real wide PiP frames them).
@Composable
private fun PipCard(modifier: Modifier = Modifier) {
    val context = LocalContext.current
    val density = LocalDensity.current
    val fontProvider = remember(context) { bundledFontProvider(context) }

    val scene = rememberReaderSceneState { parts ->
        // Keep ONLY flattened indices 1,2,3 visible: hide every other staff in the score. Force HORIZONTAL
        // so the kept staves lay out as one continuous wide single-system row (the real PiP geometry).
        val keep = HIDDEN_FLAT_INDICES
        val all = parts?.let { p -> p.flatMap { it.staves }.indices.toSet() } ?: emptySet()
        val hidden = parts?.addressesForFlatIndices(all - keep) ?: emptySet()
        LayoutOptions.DEFAULT.copy(
            mode = ReaderLayoutMode.HORIZONTAL,
            staffSize = SCREENSHOT_STAFF_SIZE,
            hiddenStaves = hidden,
        )
    }

    var cardWidthPx by remember { mutableStateOf(0) }

    if (scene == null) {
        // Reserve the card footprint while the score loads (placeholder height); the harness gate holds
        // the capture until the strip has rendered.
        Surface(
            modifier = modifier.fillMaxWidth().height(150.dp).onSizeChanged { cardWidthPx = it.width },
            shape = RoundedCornerShape(18.dp),
            shadowElevation = 14.dp,
            color = Color.White,
        ) {}
        return
    }

    val page = scene.state.program.pages.first()
    // HorizontalScore basis: fit the card width to A4 width (not the natural row width), then scroll.
    val fitPxPerMM = if (cardWidthPx > 0) (cardWidthPx / A4_WIDTH_MM).toFloat() else 0f

    // The kept three-staff row's height (document mm scaled to px), plus a little vertical air top+bottom.
    val stripHeightDp: Dp = with(density) {
        ((page.heightMM.toFloat() + PIP_VPAD_MM.toFloat() * 2f) * fitPxPerMM).toDp()
    }
    val contentWidthPx = page.widthMM.toFloat() * fitPxPerMM
    val contentHeightPx = page.heightMM.toFloat() * fitPxPerMM
    // Horizontal scroll (px) past the staff header, and the top air (px), as applied to the score row.
    val scrollLeftPx = PIP_SCROLL_LEFT_MM.toFloat() * fitPxPerMM
    val topPadPx = PIP_VPAD_MM.toFloat() * fitPxPerMM
    val scrollLeft: Dp = with(density) { scrollLeftPx.toDp() }
    val topPad: Dp = with(density) { topPadPx.toDp() }

    // Static playback cursor, recomputed once the strip is laid out. The overlay is layered as a sibling
    // of the score INSIDE the same content-sized, scroll/pad-offset Box, so both share the page's local
    // coordinate space (origin = page top-left, document mm * fitPxPerMM). That means the overlay needs no
    // panOffset and the hit-test no contentOffsetPx — the tap is already expressed in page-content px.
    //
    // DETERMINISM: the capture gate (`SceneReady.signalReady()`) is released ONLY after a non-null cursor
    // has been placed. The cursor itself is locale-independent (the music + layout are identical per
    // locale), but `signalReady()` used to fire on a fixed delay regardless of whether the hit-test had
    // produced a cursor — so any capture where `nearestCursorForTap` returned null (a tap landing on a
    // rest / between glyphs) photographed an empty overlay. We instead sweep a few tap x positions across
    // the visible window until one reliably hits a note, set `cursorFlow.value`, and only THEN signal
    // ready. If every candidate misses we throw, surfacing the real bug rather than shipping a blank frame.
    //
    // Pick a tap on a VISIBLE note: x is past the left-scroll (so it lands inside the window the card
    // shows, on notes rather than the clef/key header), y at the vertical center of the three-staff strip.
    val cursorFlow = remember { MutableStateFlow<ScoreCursor?>(null) }
    LaunchedEffect(scene.scoreHandle, fitPxPerMM, cardWidthPx) {
        if (fitPxPerMM <= 0f || cardWidthPx <= 0) return@LaunchedEffect
        val tapY = contentHeightPx * 0.5f
        // Sweep candidate x positions (as a fraction of the card width, past the left-scroll header) and
        // take the first that the hit-test resolves to a playable cursor. The fractions march rightward
        // through the visible window so the chosen note sits clearly inside the card, on the music.
        val candidateFractions = listOf(0.18f, 0.24f, 0.30f, 0.36f, 0.42f, 0.12f, 0.48f, 0.54f)
        var cursor: ScoreCursor? = null
        for (fraction in candidateFractions) {
            val tapX = scrollLeftPx + cardWidthPx.toFloat() * fraction
            cursor = nearestCursorForTap(
                tap = Offset(tapX, tapY),
                contentOffsetPx = Offset.Zero,
                pxPerMM = fitPxPerMM,
                scale = 1f,
                scoreHandle = scene.scoreHandle,
                layoutOptionsBytes = scene.layoutOptions.encode(),
            )
            if (cursor != null) break
        }
        checkNotNull(cursor) {
            "PipScene: nearestCursorForTap returned null for every candidate tap — no note in the " +
                "visible horizontal window to anchor the playback cursor."
        }
        // Place the cursor BEFORE releasing the capture gate so every locale photographs the same line.
        cursorFlow.value = cursor
        // Let the overlay draw a couple of frames over the rendered strip, then release the gate.
        kotlinx.coroutines.delay(400)
        SceneReady.signalReady()
    }

    Surface(
        modifier = modifier
            .fillMaxWidth()
            .height(if (fitPxPerMM > 0f) stripHeightDp else 150.dp)
            .onSizeChanged { cardWidthPx = it.width },
        shape = RoundedCornerShape(18.dp),
        shadowElevation = 14.dp,
        color = Color.White,
    ) {
        Box(Modifier.fillMaxSize().clipToBounds().background(Color.White)) {
            if (fitPxPerMM > 0f) {
                // The wide single-system row, scrolled left past the header (offset x) and dropped by the
                // top air (offset y), clipped to the card. Only the three kept staves are present, so the
                // row height IS the strip height.
                Box(
                    Modifier
                        .size(
                            width = with(density) { contentWidthPx.toDp() },
                            height = with(density) { contentHeightPx.toDp() },
                        )
                        .offset(x = -scrollLeft, y = topPad),
                ) {
                    ScorePage(
                        page = page,
                        fontProvider = fontProvider,
                        pxPerMM = fitPxPerMM,
                        modifier = Modifier.fillMaxSize(),
                    )
                    // Layered over the score in the SAME content space (page top-left origin), so the
                    // cursor line maps document mm → px identically to ScorePage; no pan needed because
                    // the enclosing offset Box already applies the strip's left-scroll + top air.
                    PlaybackCursorOverlay(
                        scoreHandle = scene.scoreHandle,
                        cursorFlow = cursorFlow,
                        pxPerMM = fitPxPerMM,
                        scale = 1f,
                        panOffset = Offset.Zero,
                        modifier = Modifier.fillMaxSize(),
                    )
                }
            }
        }
    }
}
