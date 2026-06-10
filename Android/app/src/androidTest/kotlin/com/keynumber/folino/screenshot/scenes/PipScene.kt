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
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.keynumber.folino.reader.LayoutOptions
import com.keynumber.folino.screenshot.fixtures.MarketingStrings
import com.keynumber.folino.screenshot.fixtures.ReaderSceneContent
import com.keynumber.folino.screenshot.fixtures.rememberReaderSceneState
import com.keynumber.folino.screenshot.frame.ScreenshotFrame
import com.keynumber.folino.screenshot.frame.ScreenshotLayout
import com.keynumber.folino.ui.theme.FolinoTheme

// PiP scene: mirrors Folino's real picture-in-picture window — a WIDE card pinned near the TOP of the
// home screen showing the score (only staves 2/3/4 = Top/2nd/3rd) with the playback cursor. The card
// hides every staff EXCEPT flattened indices 1,2,3 (the complement of the display-inspector scene's
// hidden set). The home backdrop is intentionally plain (no wallpaper art / widgets) — just a dark
// launcher with app icons and a shape-only search bar, enough to read as "playing over the home screen".
@Composable
fun PipScene(layout: ScreenshotLayout, tag: String) {
    val copy = MarketingStrings.forScene("Pip", tag)
    ScreenshotFrame(title = copy.title, subtitle = copy.subtitle, layout = layout) {
        FolinoTheme {
            Box(Modifier.fillMaxSize()) {
                FauxHomeScreen()
                // Real Folino PiP sits as a wide, short window just below the status bar.
                PipCard(Modifier.align(Alignment.TopCenter).padding(top = 40.dp, start = 10.dp, end = 10.dp))
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
            val labels = listOf("Play", "Gmail", "Photos", "YouTube", "Phone", "Chat", "Chrome", "Camera")
            AppIconRow(0..3, tints, labels)
            Spacer(Modifier.height(22.dp))
            AppIconRow(4..7, tints, labels)
            Spacer(Modifier.height(30.dp))
            SearchPill()
            Spacer(Modifier.height(18.dp))
        }
    }
}

@Composable
private fun AppIconRow(range: IntRange, tints: List<Color>, labels: List<String>) {
    Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
        for (i in range) {
            Column(horizontalAlignment = Alignment.CenterHorizontally) {
                Box(Modifier.size(54.dp).clip(CircleShape).background(tints[i]))
                Spacer(Modifier.height(6.dp))
                Text(labels[i], color = Color.White.copy(alpha = 0.92f), fontSize = 11.sp, maxLines = 1)
            }
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

// The floating PiP window: a wide, short, rounded white surface holding the score (only staves 2/3/4)
// with the playback cursor — matching Folino's real PiP, which is full-width and a few staves tall.
@Composable
private fun PipCard(modifier: Modifier = Modifier) {
    Surface(
        modifier = modifier.fillMaxWidth().height(262.dp),
        shape = RoundedCornerShape(18.dp),
        shadowElevation = 14.dp,
        color = Color.White,
    ) {
        Box(Modifier.fillMaxSize()) {
            val scene = rememberReaderSceneState { parts ->
                // Keep ONLY flattened indices 1,2,3 visible: hide every other staff in the score.
                val keep = HIDDEN_FLAT_INDICES
                val all = parts?.let { p -> p.flatMap { it.staves }.indices.toSet() } ?: emptySet()
                val hidden = parts?.addressesForFlatIndices(all - keep) ?: emptySet()
                LayoutOptions.DEFAULT.copy(hiddenStaves = hidden)
            }
            if (scene != null) {
                Box(Modifier.fillMaxSize().background(Color.White)) {
                    ReaderSceneContent(
                        state = scene.state,
                        scoreHandle = scene.scoreHandle,
                        layoutOptions = scene.layoutOptions,
                        withCursor = true,
                    )
                }
            }
        }
    }
}
